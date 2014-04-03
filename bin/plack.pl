use Dancer ':syntax';
use Plack::Builder;
use Dancer::Handler;

setting appdir => '.';
local $ENV{DANCER_APPDIR} = '.';
Dancer::Config->load;
load_app "ThisPAN";
setting apphandler => 'PSGI';
Dancer::App->set_running_app("ThisPAN");

my $dbm = sub {

    my $env = shift;
    Dancer::Handler->init_request_headers($env);
    my $req = Dancer::Request->new(env => $env);
    Dancer->dance($req);

};
 
builder {
    mount '/webopan' => $dbm;
};
