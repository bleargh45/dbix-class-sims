# vi:sw=2
use strict;
use warnings FATAL => 'all';

use Test::More;

use lib 't/lib';
use types qw(types_test);

types_test us_lastname => {
  tests => [
    [ { data_type => 'varchar' }, qr/^[\w']+(?: \w+)?(?: .+)?$/, 'Jones' ],
  ],
};

done_testing;
