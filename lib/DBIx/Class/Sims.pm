# vi:sw=2;ft=perl
package DBIx::Class::Sims;

use 5.008_004;

use strict;
use warnings FATAL => 'all';

use Data::Dumper;

use Data::Walk qw( walk );
use List::Util qw( shuffle );
use String::Random qw( random_regex random_string );

our $VERSION = 0.01;

# Guarantee that toposort is loaded.
use base 'DBIx::Class::TopoSort';

sub load_sims {
  my $self = shift;
  my ($spec_proto, $req_proto, $hooks) = @_;

  my $spec = expand_dots( normalize_input($spec_proto) );
  my $reqs = normalize_input($req_proto || {});

  ###### FROM HERE ######
  # These are utility methods to help navigate the rel_info hash.
  my $is_fk = sub { return exists $_[0]{attrs}{is_foreign_key_constraint} };
  my $short_source = sub {
    (my $x = $_[0]{source}) =~ s/.*:://;
    return $x;
  };

  my $self_fk_cols = sub { map {/^self\.(.*)/; $1} values %{$_[0]{cond}} };
  my $self_fk_col  = sub { ($self_fk_cols->(@_))[0] };
  my $foreign_fk_cols = sub { map {/^foreign\.(.*)/; $1} keys %{$_[0]{cond}} };
  my $foreign_fk_col  = sub { ($foreign_fk_cols->(@_))[0] };
  ###### TO HERE ######

  # 1. Ensure the belongs_to relationships are in $reqs
  # 2. Set the rel_info as the leaf in $reqs
  foreach my $name ( $self->sources ) {
    my $source = $self->source($name);

    $reqs->{$name} ||= {};
    foreach my $rel_name ( $source->relationships ) {
      my $rel_info = $source->relationship_info($rel_name);

      if ($is_fk->($rel_info)) {
        $reqs->{$name}{$rel_name} = 1;
      }
    }
  }

  # 2: Create the rows in toposorted order
  $hooks ||= {};
  $hooks->{preprocess}  ||= sub {};
  $hooks->{postprocess} ||= sub {};

  # Prepopulate column values (as appropriate)
  my %subs;
  $subs{fix_fk_dependencies} = sub {
    my ($name, $item) = @_;

    # 1. If we have something, then:
    #   a. If it's a scalar, then, COND = { $fk => scalar }
    #   b. Look up the row by COND
    #   c. If the row is not there, then $create_item->($fksrc, COND)
    # 2. If we don't have something, then:
    #   a. If rows exists, pick a random one.
    #   b. If rows don't exist, $create_item->($fksrc, {})
    my %child_deps;
    my $source = $self->source($name);
    foreach my $rel_name ( $source->relationships ) {
      my $rel_info = $source->relationship_info($rel_name);
      unless ( $is_fk->($rel_info) ) {
        if ($item->{$rel_name}) {
          $child_deps{$rel_name} = delete $item->{$rel_name};
        }
        next;
      }

      next unless $reqs->{$name}{$rel_name};

      my $col = $self_fk_col->($rel_info);
      my $fkcol = $foreign_fk_col->($rel_info);

      my $fk_src = $short_source->($rel_info);
      my $rs = $self->resultset($fk_src);

      if ( $item->{$rel_name} ) {
        my $cond = delete $item->{$rel_name};
        if ( ref($cond) ) {
          $rs = $rs->search($cond);
        }
        else {
          $rs = $rs->search({ $fkcol => $cond });
        }
      }
      elsif ( $item->{$col} ) {
        $rs = $rs->search({ $fkcol => $item->{$col} });
      }

      my $parent = $rs->first || $subs{create_item}->($fk_src, {});
      $item->{$col} = $parent->get_column($fkcol);
    }

    return \%child_deps;
  };
  $subs{fix_child_dependencies} = sub {
    my ($name, $row, $child_deps) = @_;

    # 1. If we have something, then:
    #   a. If it's not an array, then make it an array
    # 2. If we don't have something,
    #   a. Make an array with an empty item
    #   XXX This is more than one item would be supported
    # In all cases, make sure to add { $fkcol => $row->get_column($col) } to the
    # child's $item
    my $source = $self->source($name);
    foreach my $rel_name ( $source->relationships ) {
      my $rel_info = $source->relationship_info($rel_name);
      next if $is_fk->($rel_info);
      next unless $child_deps->{$rel_name} || $reqs->{$name}{$rel_name};

      my $col = $self_fk_col->($rel_info);
      my $fkcol = $foreign_fk_col->($rel_info);

      my $fk_src = $short_source->($rel_info);

      # Need to ensure that $child_deps >= $reqs

      my @children = @{$child_deps->{$rel_name} || []};
      @children = ( ({}) x $reqs->{$name}{$rel_name} ) unless @children;
      foreach my $child (@children) {
        $child->{$fkcol} = $row->get_column($col);
        $subs{create_item}->($fk_src, $child);
      }
    }
  };
  $subs{fix_columns} = sub {
    my ($name, $item) = @_;
    my $source = $self->source($name);
    foreach my $col_name ( $source->columns ) {
      next if exists $item->{$col_name};

      my $info = $source->column_info($col_name);
      next if grep { $_ eq $col_name } $source->primary_columns;

      if ( $info->{sim} ) {
        if ( ref($info->{sim}{func} || '') eq 'CODE' ) {
          $item->{$col_name} = $info->{sim}{func}->($info);
        }
        elsif ( $info->{sim}{type} ) {
          my $meth = __PACKAGE__->can($info->{sim}{type});
          if ( $meth ) {
            $item->{$col_name} = $meth->($info);
          }
          else {
            warn "Type '$info->{sim}{type}' is not loaded";
          }
        }
        else {
          if ( $info->{data_type} eq 'int' ) {
            my $min = $info->{sim}{min} || 0;
            my $max = $info->{sim}{max} || 100;
            $item->{$col_name} = int(rand($max-$min))+$min;
          }
          elsif ( $info->{data_type} eq 'varchar' ) {
            my $min = $info->{sim}{min} || 1;
            my $max = $info->{sim}{max} || $info->{data_length} || 255;
            $item->{$col_name} = random_regex(
              '\w' . "{$min,$max}"
            );
          }
        }
      }
    }
  };
  $subs{create_item} = sub {
    my ($name, $item) = @_;

    my $child_deps = $subs{fix_fk_dependencies}->($name, $item);
    $subs{fix_columns}->($name, $item);

    my $source = $self->source($name);
    $hooks->{preprocess}->($name, $source, $item);
    my $row = $self->resultset($name)->create($item);
    $hooks->{postprocess}->($name, $source, $row);

    $subs{fix_child_dependencies}->($name, $row, $child_deps);

    return $row;
  };

  my %ids;
  $self->txn_do(sub {
    foreach my $name ( grep { $spec->{$_} } $self->toposort() ) {
      my @pk_cols = $self->source($name)->primary_columns;
      foreach my $item ( @{$spec->{$name}} ) {
        my $row = $subs{create_item}->($name, $item);
        push @{ $ids{$name} ||= [] }, {( map { $_ => $row->$_ } @pk_cols )};
      }
    }
  });

  return \%ids;
}

sub us_zipcode {
  my ($info) = @_;

  my $datatype = $info->{data_type};
  my $sim_type = $info->{sim}{type};
  if ( $datatype eq 'varchar' || $datatype eq 'char' ) {
    my $length = $info->{size} || 9;
    if ( $length < 5 ) {
      return '';
    }
    elsif ( $length < 9 ) {
      return random_regex('\d{5}');
    }
    elsif ( $length == 9 ) {
      return random_regex('\d{9}');
    }
    else {
      return random_regex('\d{5}-\d{4}');
    }
  }
  # Must be an int
  else {
    return int(rand(99999));
  }
}

use YAML::Any qw( LoadFile Load );
sub normalize_input {
  my ($proto) = @_;

  if ( ref($proto) ) {
    return $proto;
  }

  # Doing a stat on a filename with a newline throws an error.
  my $x = eval {
    if ( -e $proto ) {
      return LoadFile($proto);
    }
  };
  return $x if $x;

  return Load($proto);
}

sub expand_dots {
  my $struct = shift;

  walk sub {
    if ( ref($_) eq 'HASH' ) {
      foreach my $k ( keys %$_ ) {
        my $t = $_;
        while ( $k =~ /([^.]*)\.(.*)/ ) {
          $t->{$1} = { $2 => delete($t->{$k}) };
          $t = $t->{$1}; $k = $2;
        }
      }
    }
  }, $struct;

  return $struct;
}

1;
__END__

=head1 NAME

DBIx::Class::Sims - The addition of simulating data to DBIx::Class

=head1 SYNOPSIS

Within your schema class:

  __PACKAGE__->load_components('Sims');

Within your resultsources, specify the sims generation rules for columns that
need specified.

  __PACKAGE__->add_columns(
    ...
    column1 => {
      data_type => 'int',
      is_nullable => 0,
      sim => {
        min => 10,
        max => 20,
      },
    },
    column2 => {
      data_type => 'varchar',
      is_nullable => 1,
      data_length => 10,
      sim => {
        func => sub {
          return String::Random::random_string('.' x 10);
        },
      },
    },
    ...
  );

Later:

  $schema->deploy({
    add_drop_table => 1,
  });
  $schema->load_sims(
    $specification,
    ?$additional_constraints,
    ?$hooks,
  );

=head1 PURPOSE

Generating test data for non-simplistic databases is extremely hard, especially
as the schema grows and changes. Designing scenarios should be doable by only
specifying the minimal elements actually used in the test with the test being
resilient to any changes in the schema that don't affect the elements specified.
This includes changes like adding a new parent table, new required child tables,
and new non-NULL columns to the table being tested.

=head1 DESCRIPTION

This is a L<DBIx::Class> component that adds a single method (generate_sims) to
L<DBIx::Class::Schema>.

=head1 METHODS

=head2 $rv = $schema->load_sims( $spec, ?$constraints, ?$hooks )

This method will load the rows requested in C<$spec>, plus any additional rows
necessary to make those rows work. This includes any parent rows (as defined by
C<belongs_to>) and per any constraints defined in C<$constraints>. If need-be,
you can pass in hooks (as described below) to manipulate the data.

load_sims does all of its work within a call to L<DBIx::Class::Schema/txn_do>.
If anything goes wrong, load_sims will rethrow the error after the transaction
is rolled back.

This, of course, assumes that the tables you are working with support
transactions. (I'm looking at you, MyISAM!) If they do not, that is on you.

=head3 Return value

This will return a hash of arrays of hashes. This will match the C<$spec>,
except that where the C<$spec> has a requested set of things to make, the return
will have the primary columns.

Examples:

If you have a table foo with "id" as the primary column and you requested:

  {
    Foo => [
      { name => 'bar' },
    ],
  }

You will receive back (assuming the next id value is 1):

  {
    Foo => [
      { id => 1 },
    ],
  }

If you have a table foo with "name" and "type" as the primary columns and you
requested:

  {
    Foo => [
      { children => [ {} ] },
    ],
  }

You will receive back (assuming the next type value is 'blah'):

  {
    Foo => [
      { name => 'bar', type => 'blah' },
    ],
  }

=head1 SPECIFICATION

The specification can be passed along as a filename that contains YAML or JSON,
a string that contains YAML or JSON, or as a hash of arrays of hashes. The
structure should look like:

  {
    ResultSourceName => [
      {
        column => $value,
        column => $value,
        relationship => {
          column => $value,
        },
        'relationship.column' => $value,
        'rel1.rel2.rel3.column' => $value,
      },
    ],
  }

If a column is a belongs_to relationship name, then the row associated with that
relationship specifier will be used. This is how you would specify a specific
parent-child relationship. (Otherwise, a random choice will be made as to which
parent to use, creating one as necessary if possible.) The dots will be followed
as far as necessary.

Columns that have not been specified will be populated in one of two ways. The
first is if the database has a default value for it. Otherwise, you can specify
the C<sim> key in the column_info for that column. This is a new key that is not
used by any other component.

(Please see L<DBIx::Class::ResultSource/add_columns> for more info.) 

B<NOTE>: The keys of the outermost hash are resultsource names. The keys within
the row-specific hashes are either columns or relationships. Not resultsources.

=head1 CONSTRAINTS

The constraints can be passed along as a filename that contains YAML or JSON, a
string that contains YAML or JSON, or as a hash of arrays of hashes. The
structure should look like:

  {
    Person => {
      addresses => 2,
    },
  }

All the C<belongs_to> relationships are automatically added to the constraints.
You can add additional constraints, as needed. The most common use for this will
be to add required child rows. For example, C<< Person->has_many('addresses') >>
would normally mean that if you create a Person, no Address rows would be
created.  But, we could specify a constraint that says "Every person must have
at least 2 addresses." Now, whenever a Person is created, two Addresses will be
added along as well, if they weren't already created through some other
specification.

=head1 HOOKS

Most people will never need to use this. But, some schema definitions may have
reasons that prevent a clean simulating with this module. For example, there may
be application-managed sequences. To that end, you may specify the following
hooks:

=over 4

=item * preprocess

This receives C<$name, $source, $spec> and expects nothing in return. C<$spec>
is the hashref that will be passed to C<<$schema->resultset($name)->create()>>.
This hook is expected to modify C<$spec> as needed.

=item * postprocess

This receives C<$name, $source, $row> and expects nothing in return. This hook
is expected to modify the newly-created row object as needed.

=back

=head1 DBIx::Class::Fixtures

L<DBIx::Class::Fixtures> is another way to load data into a database. Unlike
this module, L<DBIx::Class::Fixtures> approaches the problem by loading the same
data every time. This is complementary because some tables (such as lookup
tables of countries) want to be seeded with the same data every time. The ideal
solution would be to have a set of tables loaded with fixtures and another set
of tables loaded with sims.

=head1 SEE ALSO

L<DBIx::Class>, L<DBIx::Class::Fixtures>

=head1 AUTHOR

=over 4

=item * Rob Kinyon <rob.kinyon@gmail.com>

=back

=head1 LICENSE

Copyright (c) 2013 Rob Kinyon. All Rights Reserved.
This is free software, you may use it and distribute it under the same terms
as Perl itself.

=cut