package App::cpanminus::reporter;

use warnings;
use strict;

our $VERSION = '0.01';

use Carp ();
use File::Spec     3.19;
use File::HomeDir  0.58 ();
use Test::Reporter 1.54;
use CPAN::Testers::Common::Client;
use CPAN::Testers::Common::Client::Config;
use Parse::CPAN::Meta;
use CPAN::Meta::Converter;
use Try::Tiny;
use URI;
use Metabase::Resource;
use Capture::Tiny qw(capture);

# TODO: factor these into CPAN::Testers::Common::Client?
use Config::Tiny 2.08 ();

sub new {
  my ($class, %params) = @_;
  my $self = bless {}, $class;

  my $config = CPAN::Testers::Common::Client::Config->new;
  my $config_filename = $config->get_config_filename();
  my $config_data = Config::Tiny->read( $config_filename );

  # FIXME: poor man's validation, we should factor this out
  # from CPAN::Reporter::Config SOON!
  #FIXME: currently, this only cares for email_from and transport.
  unless ($config_data) {
    warn "Error reading configuration file '$config_filename': "
      . Config::Tiny->errstr() . "\nFalling back to default values\n";

    $config = {
      _ => {
        edit_report => 'default:no pass/na:no',
        email_from  => getpwuid($<) . '@localhost',
        send_report => 'default:yes pass/na:yes',
        transport   => 'Metabase uri https://metabase.cpantesters.org/api/v1/ id_file ' . File::Spec->catdir( $config->get_config_dir, 'metabase_id.json' ),
      },
    };
  }

  my @transport = split /\s+/ => $config_data->{_}{transport};
  my $transport_name = shift @transport
    or die 'transport method missing.';
  $config_data->{_}{transport} = {
    name => $transport_name,
    args => [ @transport ],
  };
  $config_data->{_}{email_from} = $params{email_from} if exists $params{email_from};
  $self->config( $config_data->{_} );

  $self->build_dir(
    $params{build_dir}
      || File::Spec->catdir( File::HomeDir->my_home, '.cpanm', 'latest-build' )
  );

  $self->build_logfile(
    $params{build_logfile}
      || File::Spec->catfile( $self->build_dir, 'build.log' )
  );

  # as a safety mechanism, we only let people parse build.log files
  # if they were generated up to 30 minutes (1800 seconds) ago,
  # unless the user asks us to --force it.
  my $st = lstat $self->build_logfile;
  if ( !$params{force} && time - $st->mtime > 1800 ) {
      die <<'EOMESSAGE';
Fatal: build.log was created longer than 30 minutes ago.

As a standalone tool, it is important that you run cpanm-reporter
as soon as you finish cpanm, otherwise your system data may have
changed, from new libraries to a completely different perl binary.

Because of that, this app will NOT parse build.log files last modified
longer than 30 minutes before the moment it runs.

You can override this behaviour by passing a --force flag to
cpanm-reporter, but please take good care to avoid sending bogus reports.
EOMESSAGE
  }

  $self->verbose( $params{verbose} || 0 );

  return $self;
}


## basic accessors ##

sub config {
  my ($self, $config) = @_;
  $self->{_config} = $config if $config;
  return $self->{_config};
}

sub verbose {
  my ($self, $verbose) = @_;
  $self->{_verbose} = $verbose if $verbose;
  return $self->{_verbose};
}

sub build_dir {
  my ($self, $dir) = @_;
  $self->{_build_dir} = $dir if $dir;
  return $self->{_build_dir};
}

sub build_logfile {
  my ($self, $file) = @_;
  $self->{_build_logfile} = $file if $file;
  return $self->{_build_logfile};
}


sub run {
  my $self = shift;

  my $logfile = $self->build_logfile;
  open my $fh, '<', $logfile
    or Carp::croak "error opening build log file '$logfile' for reading: $!";

  my $found = 0;
  my $parser;

  $parser = sub {
    my ($dist, $resource) = @_;
    my @test_output = ();
    my $recording = 0;
    my $str = '';
    my $fetched;

    while (<$fh>) {
      if ( /^Fetching (\S+)/ ) {
        $fetched = $1;
        $resource = $fetched unless $resource;
      }
      elsif ( /^Entering (\S+)/ ) {
        my $dep = $1;
        $found = 1;
        Carp::croak 'Parsing error. This should not happen. Please send us a report!' if $recording;
        Carp::croak "Parsing error. Found '$dep' without fetching first." unless $resource;
        print "entering $dep, $fetched\n" if $self->verbose;
        $parser->($dep, $fetched);
        print "left $dep, $fetched\n" if $self->verbose;
        next;
      }
      elsif ( $dist and /^Building and testing $dist/) {
        print "recording $dist\n" if $self->verbose;
        $recording = 1;
      }

      push @test_output, $_ if $recording;

      if ( $recording and ( /^Result: (PASS|NA|FAIL|UNKNOWN)/ or /^-> (FAIL|OK)/ ) ) {
        my $result = $1;
        $result = 'PASS' if $result eq 'OK';
        if (@test_output <= 2) {
            print "No test output found for '$dist'. Skipping...\n"
                . "To send test reports, please make sure *NOT* to pass '-v' to cpanm or your build.log will contain no output to send.\n";
        }
        else {
            my $report = $self->make_report($resource, $dist, $result, @test_output);
        }
        return;
      }
    }
  };

  print "Parsing $logfile...\n" if $self->verbose;
  $parser->();
  print "No reports found.\n" unless $found;
  print "Finished.\n" if $self->verbose;

  close $fh;
  return;
}

sub get_author {
  my ($self, $path ) = @_;
  my $metadata;

  try {
    $metadata = Metabase::Resource->new( q[cpan:///distfile/] . $path )->metadata;
  }
  catch {
    print "DEBUG: $_" if $self->verbose;
  };
  return unless $metadata;

  return $metadata->{cpan_id};
}


sub make_report {
  my ($self, $resource, $dist, $result, @test_output) = @_;

  my $uri = URI->new( $resource );
  my $scheme = lc $uri->scheme;
  if ($scheme ne 'http' and $scheme ne 'ftp' and $scheme ne 'cpan') {
    print "invalid scheme '$scheme' for resource '$resource'. Skipping...\n"
      if $self->verbose;
    return;
  }

  my $author = $self->get_author( $uri->path );
  unless ($author) {
    print "error fetching author for resource '$resource'. Skipping...\n"
      if $self->verbose;
    return;
  }

  ## NOTE: Whenever cpanm is called, it resets build.log
  ##       This is an interesting side-effect that helps us
  ##       to refrain from sending duplicate reports.
  my $cpanm_version = capture { system('cpanm -V') };
  chomp $cpanm_version;
  $cpanm_version = 'unknown cpanm' unless $cpanm_version =~ /\d+/;

  print "sending: ($resource, $author, $dist, $result)\n" if $self->verbose;

  my $meta = $self->get_meta_for( $dist );
  my $client = CPAN::Testers::Common::Client->new(
    author      => $author,
    distname    => $dist,
    grade       => $result,
    via         => "App::cpanminus::reporter $VERSION ($cpanm_version)",
    test_output => join( '', @test_output ),
    prereqs     => ($meta && ref $meta) ? $meta->{prereqs} : undef,
  );

  my $dist_file = join '/' => ($uri->path_segments)[-2,-1];
  my $reporter = Test::Reporter->new(
    transport      => $self->config->{transport}{name},
    transport_args => $self->config->{transport}{args},
    grade          => $client->grade,
    distribution   => $dist,
    distfile       => $dist_file,
    from           => $self->config->{email_from},
    comments       => $client->email,
    via            => $client->via,
  );
  $reporter->send() || die $reporter->errstr();
}

sub get_meta_for {
  my ($self, $dist) = @_;
  my $distdir = File::Spec->catdir( $self->build_dir, $dist );

  foreach my $meta_file ( qw( META.json META.yml META.yaml ) ) {
    my $meta_path = File::Spec->catfile( $distdir, $meta_file );
    if (-e $meta_path) {
      my $meta = eval { Parse::CPAN::Meta->load_file( $meta_path ) };
      next if $@;

      if (!$meta->{'meta-spec'} or $meta->{'meta-spec'}{version} < 2) {
          $meta = CPAN::Meta::Converter->new( $meta )->convert( version => 2 );
      }
      return $meta;
    }
  }
  return;
}


42;
__END__

=head1 NAME

App::cpanminus::reporter - send cpanm output to CPAN Testers

=head1 SYNOPSIS

This is just the backend module, you are probably looking for L<cpanm-reporter>'s
documentation instead. Please look there for a much comprehensive documentation.


=head1 STILL HERE?

    use App::cpanminus::reporter;
    my $tester = App::cpanminus::reporter->new( %options );

    $tester->run;

  
=head1 DESCRIPTION

See L<cpanm-reporter>.


=head1 BUGS AND LIMITATIONS

=head2 Time of Check x Time of Use

This is a standalone tool that reads cpanm's C<build.log> file, meaning
it can potentially be run any time after cpanm has done its thing. As such,
you must be cautious to only run this tool I<right after> you run cpanm,
otherwise your whole environment may have changed, rendering the report
useless - maybe even turning it into a disservice.

B<< As such, we will *only* parse build.log files last modified up to 30
minutes before. >> You can override this by passing the C<--force> flag
to cpanm-reporter, but please take good care to avoid sending bogus reports.

Please report any bugs or feature requests to
C<bug-app-cpanminus-reporter@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Breno G. de Oliveira  C<< <garu@cpan.org> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2012, Breno G. de Oliveira C<< <garu@cpan.org> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
