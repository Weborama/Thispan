use Module::Build;

my $build = Module::Build->new(
    module_name => 'ThisPAN',
    dist_abstract => 'Lightweight CPAN mirror explorer',
    dist_author => 'Fabrice Gabolde <fgabolde@weborama.com>',
    dist_version_from => 'lib/ThisPAN.pm',
    license => 'gpl',
    configure_requires => {
        'Module::Build' => '0.36_14',
    },
    test_requires => {
        'Test::More' => 0,
    },
    requires => {
        'perl' => '5.10.0',
        'Archive::Extract' => 0,
        'autodie' => 0,
        'base' => 0,
        'Carp' => 0,
        'CPAN::Meta' => 0,
        # need merged_requirements() support
        'CPAN::Meta::Prereqs' => '2.132830',
        'CPAN::Meta::Requirements' => 0,
        'Dancer' => 0,
        'Dancer::Plugin::DBIC' => 0,
        'DateTime' => 0,
        'DBIx::Class' => 0,
        'File::Copy' => 0,
        'File::Temp' => 0,
        'Graph' => 0,
        'HTTP::Tiny' => 0,
        'IO::File' => 0,
        # needed for autodie qw/system/
        'IPC::System::Simple' => 0,
        # convert_blessed_universally has been "experimental" since
        # 2008
        'JSON' => 2.07,
        'List::MoreUtils' => 0,
        # need first_release() support
        'Module::CoreList' => 2.21,
        'Moo' => 0,
        'Params::Validate' => 0,
        'Path::Class' => 0,
        'Pod::Simple::XHTML' => 0,
        'Scalar::Util' => 0,
        'Storable' => 0,
        'strict' => 0,
        'Template' => 0,
        'Try::Tiny' => 0,
        'URI' => 0,
        'utf8' => 0,
        'warnings' => 0,
        'YAML' => 0,
    },
    add_to_cleanup => [ 'ThisPAN-*' ],
    meta_merge => {
        resources => {
            repository => 'https://github.com/Weborama/Thispan.git',
            bugtracker => 'https://github.com/Weborama/Thispan/issues',
        },
    },);

$build->create_build_script;
