use Test2::Bundle::Extended -target => 'Test2::AsyncSubtest';
use Test2::AsyncSubtest;
use Test2::Util qw/get_tid CAN_THREAD CAN_REALLY_FORK/;
use Test2::API qw/intercept/;

ok($INC{'Test2/IPC.pm'}, "Loaded Test2::IPC");

# Preserve the API
can_ok $CLASS => qw{
    name hub trace send_to events finished active stack id children pid tid

    context cleave attach detach ready pending run start stop finish wait fork
    run_fork run_thread
};

my $file = __FILE__;
my $line;
like(
    dies { $line = __LINE__; $CLASS->new },
    qr/'name' is a required attribute at \Q$file\E line $line/,
    "Must provide name"
);

my ($one, $two, $three, $hub);
my %lines;
intercept {
    $lines{one} = __LINE__ + 1;
    $one = $CLASS->new(name => 'one');
    $hub = Test2::API::test2_stack()->top;

    $one->run(sub {
        $lines{two} = __LINE__ + 1;
        $two = $CLASS->new(name => 'two');
        $two->run(sub {
            $lines{three} = __LINE__ + 1;
            $three = $CLASS->new(name => 'three');
        });
    });
};
isa_ok($one, $CLASS);

like(
    $one,
    {
        name     => 'one',
        send_to  => exact_ref($hub),
        trace    => {frame => [__PACKAGE__, __FILE__, $lines{one}]},
        stack    => [],
        _in_use  => 2,
        tid      => get_tid,
        pid      => $$,
        finished => 0,
        id       => 1,
        active   => 0,
        children => [],
        hub => meta { prop blessed => 'Test2::AsyncSubtest::Hub' },
        events => array {},
    },
    "Got expected properties from construction part 1"
);

like(
    $two,
    {
        name     => 'two',
        send_to  => exact_ref($one->hub),
        trace    => {frame => [__PACKAGE__, __FILE__, $lines{two}]},
        stack    => [exact_ref($one)],
        _in_use  => 1,
        tid      => get_tid,
        pid      => $$,
        finished => 0,
        id       => 1,
        active   => 0,
        children => [],
        hub => meta { prop blessed => 'Test2::AsyncSubtest::Hub' },
        events => array {},
    },
    "Got expected properties from construction part 2"
);

like(
    $three,
    {
        name     => 'three',
        send_to  => exact_ref($two->hub),
        trace    => {frame => [__PACKAGE__, __FILE__, $lines{three}]},
        stack    => [exact_ref($one), exact_ref($two)],
        _in_use  => 0,
        tid      => get_tid,
        pid      => $$,
        finished => 0,
        id       => 1,
        active   => 0,
        children => [],
        hub => meta { prop blessed => 'Test2::AsyncSubtest::Hub' },
        events => array {},
    },
    "Got expected properties from construction part 3"
);

$_->finish for $three, $two, $one;

is(
    intercept {
        my $st = Test2::AsyncSubtest->new(name => 'collapse: empty');
        $st->finish(collapse => 1);
    },
    array {
        event Ok => {
            pass => 1,
            name => 'collapse: empty',
        };
        end;
    },
    "Got 1 ok event for collapsed/empty subtest"
);

is(
    intercept {
        my $st = Test2::AsyncSubtest->new(name => 'collapse: note only');
        $st->run(sub { note "inside" });
        $st->finish(collapse => 1);
    },
    array {
        event Subtest => sub {
            call pass => 1;
            call name => 'collapse: note only';
            call subevents => array {
                event Note => { message => "inside" };
                end;
            };
        };
        end;
    },
    "Got subtest event containing only the note"
);

is(
    intercept {
        my $st = Test2::AsyncSubtest->new(name => 'collapse: full');
        $st->run(sub { ok(1, "test") });
        $st->finish(collapse => 1);
    },
    array {
        event Subtest => sub {
            call pass => 1;
            call name => 'collapse: full';
            call subevents => array {
                event Ok => { pass => 1 };
                event Plan => { max => 1 };
                end;
            };
        };
        end;
    },
    "Got full subtest"
);

is(
    intercept {
        my $st = Test2::AsyncSubtest->new(name => 'collapse: no assert, but fail');
        $st->hub->set_failed(1);
        $st->finish(collapse => 1);
    },
    array {
        fail_events Ok => sub {
            call pass => 0;
            call name => 'collapse: no assert, but fail';
        };
        end;
    },
    "Failure with no assertion (no test count)"
);


is(
    intercept {
        my $st = Test2::AsyncSubtest->new(name => 'skip test');
        $st->finish(skip => "foo bar");
    },
    array {
        event Skip => { name => 'skip test', reason => 'foo bar' };
        end;
    },
    "Can skip"
);

my $error;
intercept {
    my $control = mock 'Test2::Hub' => (
        override => [ is_local => sub { 0 } ],
    );

    my $st = Test2::AsyncSubtest->new(name => 'early');
    $error = dies { $st->run(sub { diag("We want to see this message or people die!") }) };
    $control = undef;
    $st->finish();
};

like(
    $error,
    qr/We want to see this message or people die!/,
    "When an event is seen to early we get to see it in our exception"
);

like(
    $error,
    qr/You must attach to an AsyncSubtest before you can send events to it from another process or thread/,
    "We see the main exception"
);

done_testing;
