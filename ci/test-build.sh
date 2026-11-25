#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

perl - "$PWD/build.sh" <<'PERL'
use strict;
use warnings;
use File::Basename qw(basename);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json encode_json);

my $source = shift;
open my $input, '<', $source or die "$source: $!\n";
my $build = do { local $/; <$input> };
my $replaced = $build =~ s/^cache_root=\$HOME\/Library\/Caches\/ca\.aqsnow\.alfred\.spotify\/build$/cache_root=\$BUILD_FIXTURE_CACHE/m;
die "Build cache fixture must replace exactly one cache_root line\n" unless $replaced == 1;
my $root = tempdir('spotify-build-regression-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $development = 'A' x 40;
my $distribution = 'B' x 40;

sub write_file {
  my ($path, $contents, $executable) = @_;
  open my $file, '>', $path or die "$path: $!\n";
  print {$file} $contents;
  close $file or die "$path: $!\n";
  chmod 0755, $path if $executable;
}
sub read_file {
  open my $file, '<', $_[0] or die "$_[0]: $!\n";
  local $/;
  return <$file>;
}
sub check { die "FAILED: Build regression test: $_[1]\n" unless $_[0] }

make_path("$root/bin");
write_file("$root/bin/mock", <<'MOCK', 1);
#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(basename);
use File::Copy qw(copy);
use JSON::PP qw(decode_json encode_json);
my $root = $ENV{BUILD_FIXTURE_CASE};
my $tool = basename($0);
open my $log, '>>', "$root/calls" or die $!;
print {$log} encode_json([$tool, @ARGV]), "\n";
close $log;
open my $input, '<', "$root/state" or die $!;
my $state = decode_json(do { local $/; <$input> });
close $input;
sub save {
  open my $output, '>', "$root/state" or die $!;
  print {$output} encode_json($state);
  close $output;
}
sub output_path {
  for my $i (0 .. $#ARGV - 1) {
    return $ARGV[$i + 1] if $ARGV[$i] eq '-o' || $ARGV[$i] eq '-output';
  }
  die "No output in $tool @ARGV\n";
}
sub plist {
  my (%values) = @_;
  print qq{<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>};
  print "<key>$_</key><string>$values{$_}</string>" for sort keys %values;
  print "</dict></plist>\n";
}
if ($tool eq 'security') {
  die "Unexpected security arguments\n" unless join(' ', @ARGV) eq 'find-identity -v -p codesigning';
  print $state->{identities};
} elsif ($tool eq 'open') {
  die "Unexpected open arguments\n" unless @ARGV == 2 && $ARGV[0] eq '-R';
} elsif ($tool eq 'codesign') {
  if (grep { $_ eq '--verify' } @ARGV) {
    die "fixture signature rejected\n" if $state->{fail} eq 'signature';
    my $target = $ARGV[-1];
    my $signature = -d $target ? "$target/Contents/fixture-signature" : "$target.signature";
    die "Missing fixture signature: $target\n" unless -f $signature;
  } else {
    die "fixture signing identity rejected\n" if $state->{fail} eq 'signing';
    die "Unexpected signing arguments\n" unless $ARGV[0] eq '--force' && $ARGV[1] eq '--sign';
    my $target = $ARGV[-1];
    my $signature = -d $target ? "$target/Contents/fixture-signature" : "$target.signature";
    open my $signed, '>', $signature or die $!;
    print {$signed} "$ARGV[2]\n";
    close $signed;
  }
} elsif ($tool eq 'spctl') {
  die "fixture assessment rejected\n" if $state->{fail} eq 'assessment';
  die "Assessment requires a stapled ticket\n" unless -f "$ARGV[-1]/Contents/CodeResources";
} elsif ($tool eq 'xcrun') {
  my $command = shift @ARGV;
  if ($command eq '--show-sdk-path') { print "/fixture/MacOSX.sdk\n" }
  elsif ($command eq '--show-sdk-build-version') { print "fixture-sdk\n" }
  elsif ($command eq 'swiftc' || $command eq 'clang') {
    if (@ARGV == 1 && $ARGV[0] eq '--version') { print "$command fixture version\n"; exit 0 }
    my $path = output_path();
    open my $output, '>', $path or die $!;
    if ($command eq 'swiftc') {
      print {$output} <<'PLAYER';
#!/bin/sh
set -eu
[ "$1" = --write-metadata ]
printf '<plist version="1.0"><dict/></plist>\n' >"$3/info.plist"
printf '<plist version="1.0"><dict/></plist>\n' >"$3/Spotify Mini Player.app/Contents/Info.plist"
PLAYER
    } else { print {$output} "#!/bin/sh\nexit 0\n" }
    close $output;
    chmod 0755, $path;
  } elsif ($command eq 'lipo') {
    copy($ARGV[1], output_path()) or die $!;
    chmod 0755, output_path();
  } elsif ($command eq 'notarytool') {
    my $action = shift @ARGV;
    my $profile;
    my $format;
    for my $i (0 .. $#ARGV - 1) {
      $profile = $ARGV[$i + 1] if $ARGV[$i] eq '--keychain-profile';
      $format = $ARGV[$i + 1] if $ARGV[$i] eq '--output-format' || $ARGV[$i] eq '-f';
    }
    die "Unexpected notarization profile\n" unless defined $profile && $profile eq 'alfred-spotify';
    if ($action eq 'submit') {
      die "Submit must not wait\n" unless grep { $_ eq '--no-wait' } @ARGV;
      die "Submission must return plist\n" unless defined $format && $format eq 'plist';
      die "Submission archive missing\n" unless -f $ARGV[0];
      $state->{submissions}++;
      $state->{id} = sprintf '00000000-0000-0000-0000-%012d', $state->{submissions};
      save();
      plist(id => $state->{id}, status => 'In Progress');
    } elsif ($action eq 'wait') {
      die "Wait used another submission ID\n" unless $ARGV[0] eq $state->{id};
      die "Wait must return plist\n" unless defined $format && $format eq 'plist';
      if ($state->{wait_fail_remaining}) {
        $state->{wait_fail_remaining}--;
        save();
        die "fixture wait interrupted\n";
      }
      plist(id => $state->{id}, status => $state->{status});
      exit($state->{wait_exit} // 0);
    } elsif ($action eq 'log') {
      die "Log used another submission ID\n" unless $ARGV[0] eq $state->{id};
      print "fixture notarization rejected: invalid signature\n";
    } else { die "Unexpected notarytool action: $action\n" }
  } elsif ($command eq 'stapler') {
    my $action = shift @ARGV;
    my $ticket = "$ARGV[-1]/Contents/CodeResources";
    if ($action eq 'staple') {
      die "fixture staple failed\n" if $state->{fail} eq 'staple';
      open my $output, '>', $ticket or die $!;
      print {$output} $state->{id};
      close $output;
      system('/usr/bin/xattr', '-w', 'com.aqsnow.fixture.notary', $state->{id}, $ARGV[-1]) == 0 or die "Could not attach fixture ticket metadata\n";
    } elsif ($action eq 'validate') {
      die "fixture ticket invalid\n" if $state->{fail} eq 'ticket';
      die "Missing stapled ticket\n" unless -f $ticket;
    } else { die "Unexpected stapler action: $action\n" }
  } else { die "Unexpected xcrun command: $command\n" }
} else { die "Unexpected mock tool: $tool\n" }
MOCK
for my $tool (qw(xcrun security codesign spctl open)) {
  symlink 'mock', "$root/bin/$tool" or die $!;
}

sub fixture {
  my ($name, %extra) = @_;
  my $case = "$root/$name";
  my $repo = "$case/repo";
  make_path(map { "$repo/$_" } qw(src/vendor workflow docs));
  make_path("$case/external cwd");
  write_file("$repo/build.sh", $build, 1);
  write_file("$repo/src/main.swift", qq{let version = "v1.2.3-test"\n});
  write_file("$repo/src/Bridge.c", 'fixture bridge');
  write_file("$repo/src/Bridge.h", 'fixture header');
  write_file("$repo/src/launcher.c", 'fixture launcher');
  write_file("$repo/src/Entitlements.plist", '<plist version="1.0"><dict/></plist>');
  write_file("$repo/src/vendor/zstddeclib.c", 'fixture decoder');
  write_file("$repo/src/vendor/ZSTD-LICENSE", 'fixture license');
  write_file("$repo/workflow/icon.png", 'fixture icon');
  system('/usr/bin/xattr', '-w', 'com.aqsnow.fixture.source', 'fixture', "$repo/workflow/icon.png") == 0 or die $!;
  write_file("$repo/workflow/spotify-liked-songs.png", 'fixture liked songs');
  write_file("$repo/docs/screenshot.png", 'fixture screenshot');
  write_file("$repo/README.md", 'fixture help');
  write_file("$case/state", encode_json({
    identities => qq{  1) $distribution "Developer ID Application: Fixture (TEAM123456)"\n     1 valid identities found\n},
    fail => '', status => 'Accepted', submissions => 0, wait_fail_remaining => 0, %extra,
  }));
  return $case;
}
sub state {
  my ($case, %changes) = @_;
  my $value = decode_json(read_file("$case/state"));
  @$value{keys %changes} = values %changes;
  write_file("$case/state", encode_json($value)) if %changes;
  return $value;
}
sub calls {
  my ($case, $tool, $action) = @_;
  return [] unless -f "$case/calls";
  my @calls = map { decode_json($_) } split /\n/, read_file("$case/calls");
  return [grep { $_->[0] eq $tool && (!defined $action || ($_->[1] // '') eq $action) } @calls];
}
sub run {
  my ($case, $expected, @arguments) = @_;
  my $child = fork();
  die "fork: $!\n" unless defined $child;
  if (!$child) {
    $ENV{PATH} = "$root/bin:$ENV{PATH}";
    $ENV{BUILD_FIXTURE_CASE} = $case;
    $ENV{BUILD_FIXTURE_CACHE} = "$case/cache";
    chdir "$case/external cwd" or die $!;
    open STDOUT, '>', "$case/stdout" or die $!;
    open STDERR, '>', "$case/stderr" or die $!;
    exec '/bin/sh', "$case/repo/build.sh", @arguments;
    die "exec: $!\n";
  }
  waitpid $child, 0;
  my $success = $? == 0;
  unless ($success == $expected) {
    die "FAILED: Build regression test: " . basename($case) . " unexpected status $?\n" . read_file("$case/stderr");
  }
}
sub output { return "$_[0]/external cwd/output with spaces/Spotify.alfredworkflow" }
sub preserved_failure {
  my ($name, %extra) = @_;
  my $case = fixture($name, %extra);
  make_path("$case/external cwd/output with spaces");
  write_file(output($case), 'previous release');
  run($case, 0, '--notarize', 'output with spaces/Spotify.alfredworkflow');
  check(read_file(output($case)) eq 'previous release', "$name preserves the previous output");
  return $case;
}
sub archive_entries {
  open my $unzip, '-|', '/usr/bin/unzip', '-Z', '-1', $_[0] or die $!;
  my @entries = <$unzip>;
  close $unzip or die "Could not list export archive\n";
  return @entries;
}
sub ticket {
  my ($case) = @_;
  check(!grep(m{(?:^|/)\._}, archive_entries(output($case))),
    'notarized export contains no AppleDouble files that invalidate imported app signatures');
  open my $unzip, '-|', '/usr/bin/unzip', '-p', output($case), 'Spotify Mini Player.app/Contents/CodeResources' or die $!;
  my $contents = do { local $/; <$unzip> };
  close $unzip or die "Could not read stapled ticket\n";
  return $contents;
}
sub no_notary_cache {
  my ($case) = @_;
  my @files;
  require File::Find;
  File::Find::find(sub { push @files, $_ if /^(?:signed\.zip|submission\.plist|result\.plist|notarized\.zip)$/ }, "$case/cache") if -d "$case/cache";
  check(!@files, basename($case) . ' creates no notarization cache');
  check(!@{calls($case, 'xcrun', 'notarytool')}, basename($case) . ' does not submit to Apple');
  check(!@{calls($case, 'xcrun', 'stapler')}, basename($case) . ' does not staple');
}

for my $mode (
  ['ordinary', [], 'Spotify-dev.alfredworkflow', 'Spotify.alfredworkflow'],
  ['test', ['--test'], 'Spotify-dev.alfredworkflow', 'Spotify.alfredworkflow'],
  ['notarized', ['--notarize'], 'Spotify.alfredworkflow', 'Spotify-dev.alfredworkflow'],
) {
  my ($name, $flags, $written, $untouched) = @$mode;
  my $case = fixture("default-output-$name");
  make_path("$case/repo/dist");
  write_file("$case/repo/dist/$untouched", 'previous export');
  run($case, 1, @$flags);
  check(-s "$case/repo/dist/$written"
    && read_file("$case/repo/dist/$untouched") eq 'previous export'
    && read_file("$case/stdout") eq "dist/$written\n",
    "$name default output keeps development and release exports separate");
}

my $default = fixture('default', identities => qq{  1) $development "Apple Development: Fixture (TEAM123456)"\n});
run($default, 1, 'output with spaces/Spotify.alfredworkflow');
check(-f output($default), 'default build exports successfully from another working directory');
no_notary_cache($default);
my $test = fixture('test', identities => '');
run($test, 1, '--test', 'output with spaces/Spotify.alfredworkflow');
check(-f output($test) && !@{calls($test, 'security')}, 'test export does not inspect credentials');
no_notary_cache($test);
for my $case ($default, $test) {
  my $signs = calls($case, 'codesign');
  my $identity = $case eq $test ? '-' : $development;
  check(@$signs == 2 && !grep({ $_->[3] ne $identity || $_->[4] ne '--timestamp=none' } @$signs), basename($case) . ' uses the expected signing identity and timestamp');
}
for my $identities ('', qq{  1) $development "Apple Development: Fixture (TEAM123456)"\n}) {
  my $case = fixture('missing-developer-id-' . length($identities), identities => $identities);
  run($case, 0, '--notarize', 'output with spaces/Spotify.alfredworkflow');
  check(!-f output($case) && !@{calls($case, 'codesign')} && !@{calls($case, 'xcrun')}, 'notarization requires Developer ID before compiling or publishing');
}
for my $flags (['--test', '--notarize'], ['--notarize', '--test']) {
  my $case = fixture('conflict-' . $flags->[0]);
  run($case, 0, @$flags, 'output with spaces/Spotify.alfredworkflow');
  check(!-f output($case) && !-d "$case/cache" && !@{calls($case, 'codesign')}, 'conflicting flags are rejected before output or cache writes');
}
my $accepted = fixture('accepted', identities => qq{  1) $development "Apple Development: Fixture (TEAM123456)"\n  2) $distribution "Developer ID Application: Fixture (TEAM123456)"\n});
run($accepted, 1, '--notarize', 'output with spaces/Spotify.alfredworkflow');
check(ticket($accepted) eq state($accepted)->{id}, 'published workflow archive contains the actual stapled app ticket');
my $signs = calls($accepted, 'codesign');
my @signing = grep { $_->[1] eq '--force' } @$signs;
my @verification = grep { grep { $_ eq '--verify' } @$_ } @$signs;
check(@signing == 2 && !grep({ $_->[3] ne $distribution || $_->[4] ne '--timestamp' } @signing), 'notarized build prefers Developer ID and requests a secure timestamp');
check(@verification >= 2 && @{calls($accepted, 'spctl')} == 1, 'launcher and app signatures and Gatekeeper assessment are verified');
my @cached_exports;
File::Find::find({ no_chdir => 1, wanted => sub { push @cached_exports, $_ if m{/notarized\.zip\z} } }, "$accepted/cache");
check(@cached_exports == 1, 'accepted export has one reusable notarization cache');
my $legacy_stage = tempdir('legacy-export-XXXXXX', DIR => $root);
system('/usr/bin/ditto', '-x', '-k', $cached_exports[0], $legacy_stage) == 0 or die $!;
system('/usr/bin/xattr', '-w', 'com.aqsnow.fixture.legacy', 'fixture',
  "$legacy_stage/Spotify Mini Player.app/Contents/Resources/icon.png") == 0 or die $!;
system('/usr/bin/ditto', '-c', '-k', $legacy_stage, "$accepted/legacy.zip") == 0 or die $!;
check(scalar(grep(m{(?:^|/)\._}, archive_entries("$accepted/legacy.zip"))),
  'legacy cache fixture contains AppleDouble metadata');
copy("$accepted/legacy.zip", $cached_exports[0]) or die $!;
sub mutations {
  my ($case) = @_;
  return scalar(grep { $_->[1] eq '--force' } @{calls($case, 'codesign')})
    + scalar(@{calls($case, 'xcrun', 'notarytool')})
    + scalar(grep { $_->[2] eq 'staple' } @{calls($case, 'xcrun', 'stapler')});
}
my $before = mutations($accepted);
run($accepted, 1, '--notarize', 'output with spaces/Spotify.alfredworkflow');
my $after = mutations($accepted);
check($before == $after && ticket($accepted) eq state($accepted)->{id}
  && !grep(m{(?:^|/)\._}, archive_entries($cached_exports[0])),
  'legacy accepted cache is repaired without signing, submitting or stapling');
write_file("$accepted/repo/workflow/icon.png", 'changed fixture icon');
run($accepted, 1, '--notarize', 'output with spaces/Spotify.alfredworkflow');
check(state($accepted)->{submissions} == 2 && ticket($accepted) eq state($accepted)->{id}, 'changed payload starts a new submission and receives its own ticket');
my $resume = preserved_failure('interrupted-wait', wait_fail_remaining => 1);
check(state($resume)->{submissions} == 1, 'interrupted wait leaves exactly one submission');
my $id = state($resume)->{id};
my $resume_signatures = scalar grep { $_->[1] eq '--force' } @{calls($resume, 'codesign')};
run($resume, 1, '--notarize', 'output with spaces/Spotify.alfredworkflow');
check(state($resume)->{submissions} == 1 && state($resume)->{id} eq $id && ticket($resume) eq $id
  && scalar(grep { $_->[1] eq '--force' } @{calls($resume, 'codesign')}) == $resume_signatures, 'interrupted wait resumes the same submission without resubmitting');
for my $exit (0, 1) {
  my $invalid = preserved_failure("invalid-status-$exit", status => 'Invalid', wait_exit => $exit);
  check(read_file("$invalid/stderr") =~ /fixture notarization rejected/,
    "Invalid status fetches and reports the notarization log with wait exit $exit");
}
preserved_failure("failed-$_", fail => $_) for qw(signing staple signature ticket assessment);
print "Build regression tests passed: signing, stapled archives, resumable notarization, cache invalidation, and preserved outputs.\n";
PERL
