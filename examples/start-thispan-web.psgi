use Dancer ':syntax';
use Plack::Builder;
use Dancer::Handler;

# if ThisPAN is not in your @INC already
# use lib 'path/to/ThisPAN/lib';

# reasonable-looking values assuming the app is installed system-wide
# -- appdir is where Dancer will go look for the views/ and public/
# directory, but also the logs, unfortunately
setting appdir => '/usr/share/thispan';
# some voodoo.  appdir actually needs to be set twice like this --
# first one allows the very first logs to go somewhere, but if second
# one is missing then e.g. the views directory will not be configured
# correctly.
local $ENV{DANCER_APPDIR} = '/usr/share/thispan';

# looks at /etc/thispan/config.yml,
# /etc/thispan/environments/[ENVIRONMENT].yml, where ENVIRONMENT is
# set with e.g. plackup -E ENVIRONMENT
setting confdir => '/etc/thispan';
setting envdir => '/etc/thispan/environments';
Dancer::Config->load;

# load the main module of our app and designate it as a Dancer app
load_app "ThisPAN";
setting apphandler => 'PSGI';
Dancer::App->set_running_app("ThisPAN");

# your basic voodoo incantation to create a PSGI app
my $app = sub {
    my $env = shift;
    Dancer::Handler->init_request_headers($env);
    my $req = Dancer::Request->new(env => $env);
    Dancer->dance($req);
};
 
builder {
    # enable middlewares here
    mount '/wherever' => $app;
};
