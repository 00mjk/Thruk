package Thruk::Utils::CookieAuth;

=head1 NAME

Thruk::Utils::CookieAuth - Utilities Collection for Cookie Authentication

=head1 DESCRIPTION

Cookie Authentication offers a nice login mask and makes it possible
to logout again.

=cut

use warnings;
use strict;
use Thruk::UserAgent;
use Thruk::Authentication::User;
use Thruk::Utils;
use Thruk::Utils::IO;
use Data::Dumper;
use Encode qw/encode_utf8/;
use Digest ();
use File::Slurp qw/read_file/;
use Carp qw/confess/;
use File::Copy qw/move/;
use Crypt::Rijndael ();
use MIME::Base64 ();

##############################################
my $supported_digests = {
    "1"  => 'SHA-256',
};
my $default_digest        = 1;
my $hashed_key_file_regex = qr/^([a-zA-Z0-9]+)(\.[A-Z]+\-\d+|)$/mx;
my $session_key_regex     = qr/^([a-zA-Z0-9]+)(|_\d{1})$/mx;

##############################################

=head1 METHODS

=head2 external_authentication

    external_authentication($config, $login, $pass, $address)

verify authentication by external login into external url

return:

    sid  if login was ok
    0    if login failed
   -1    on technical problems

=cut
sub external_authentication {
    my($config, $login, $pass, $address, $stats) = @_;
    my $authurl  = $config->{'cookie_auth_restricted_url'};
    my $sdir     = $config->{'var_path'}.'/sessions';
    Thruk::Utils::IO::mkdir($sdir);

    my $netloc = Thruk::Utils::CookieAuth::get_netloc($authurl);
    my $ua     = get_user_agent($config);
    # unset proxy which eventually has been set from https backends
    local $ENV{'HTTPS_PROXY'} = undef if exists $ENV{'HTTPS_PROXY'};
    local $ENV{'HTTP_PROXY'}  = undef if exists $ENV{'HTTP_PROXY'};
    # bypass ssl host verfication on localhost
    $ua->ssl_opts('verify_hostname' => 0) if($authurl =~ m/^(http|https):\/\/localhost/mx or $authurl =~ m/^(http|https):\/\/127\./mx);
    $stats->profile(begin => "ext::auth: post1 ".$authurl) if $stats;
    my $res      = $ua->post($authurl);
    $stats->profile(end   => "ext::auth: post1 ".$authurl) if $stats;
    if($res->code == 302 && $authurl =~ m|^http:|mx) {
        (my $authurl_https = $authurl) =~ s|^http:|https:|gmx;
        if($res->{'_headers'}->{'location'} eq $authurl_https) {
            $config->{'cookie_auth_restricted_url'} = $authurl_https;
            return(external_authentication($config, $login, $pass, $address, $stats));
        }
    }
    if($res->code == 401) {
        my $realm = $res->header('www-authenticate');
        if($realm =~ m/Basic\ realm=\"([^"]+)\"/mx) {
            $realm = $1;
            # LWP requires perl internal format
            if(ref $login eq 'HASH') {
                for my $header (keys %{$login}) {
                    $ua->default_header( $header => $login->{$header} );
                }
            } else {
                $login = encode_utf8(Thruk::Utils::ensure_utf8($login));
                $pass  = encode_utf8(Thruk::Utils::ensure_utf8($pass));
                $ua->credentials( $netloc, $realm, $login, $pass );
            }
            $stats->profile(begin => "ext::auth: post2 ".$authurl) if $stats;
            $res = $ua->post($authurl);
            $stats->profile(end   => "ext::auth: post2 ".$authurl) if $stats;
            if($res->code == 200 and $res->request->header('authorization') and $res->decoded_content =~ m/^OK:\ (.*)$/mx) {
                if(ref $login eq 'HASH') { $login = $1; }
                if($1 eq Thruk::Authentication::User::transform_username($config, $login)) {
                    my $hash = $res->request->header('authorization');
                    $hash =~ s/^Basic\ //mx;
                    $hash = 'none' if $config->{'cookie_auth_session_cache_timeout'} == 0;
                    my($sessionid) = store_session($config, undef, {
                        hash       => $hash,
                        address    => $address,
                        username   => $login,
                    });
                    return $sessionid;
                }
            } else {
                $login = '(by basic auth hash)' if ref $login eq 'HASH';
                print STDERR 'authorization failed for user ', $login,' got rc ', $res->code, "\n";
                return 0;
            }
        } else {
            print STDERR 'auth: realm does not match, got ', $realm, "\n";
        }
    } else {
        print STDERR 'auth: expected code 401, got ', $res->code, "\n", Dumper($res);
    }
    return -1;
}

##############################################

=head2 verify_basic_auth

    verify_basic_auth($config, $basic_auth)

verify authentication by sending request with basic auth header.

returns  1 if authentication was successfull
returns -1 on timeout error
returns  0 if unsuccessful

=cut
sub verify_basic_auth {
    my($config, $basic_auth, $login, $timeout) = @_;
    my $authurl  = $config->{'cookie_auth_restricted_url'};

    # unset proxy which eventually has been set from https backends
    local $ENV{'HTTPS_PROXY'} = undef if exists $ENV{'HTTPS_PROXY'};
    local $ENV{'HTTP_PROXY'}  = undef if exists $ENV{'HTTP_PROXY'};

    my $ua = get_user_agent($config);
    $ua->timeout($timeout) if $timeout;
    # bypass ssl host verfication on localhost
    $ua->ssl_opts('verify_hostname' => 0 ) if($authurl =~ m/^(http|https):\/\/localhost/mx or $authurl =~ m/^(http|https):\/\/127\./mx);
    $ua->default_header( 'Authorization' => 'Basic '.$basic_auth );
    printf(STDERR "thruk_auth: basic auth request for %s to %s\n", $login, $authurl) if ($ENV{'THRUK_COOKIE_AUTH_VERBOSE'} && $ENV{'THRUK_COOKIE_AUTH_VERBOSE'} > 1);
    my $res = $ua->post($authurl);
    if($res->code == 302 && $authurl =~ m|^http:|mx) {
        (my $authurl_https = $authurl) =~ s|^http:|https:|gmx;
        if($res->{'_headers'}->{'location'} eq $authurl_https) {
            printf(STDERR "thruk_auth: basic auth redirects to %s\n", $authurl_https) if ($ENV{'THRUK_COOKIE_AUTH_VERBOSE'} && $ENV{'THRUK_COOKIE_AUTH_VERBOSE'} > 1);
            $config->{'cookie_auth_restricted_url'} = $authurl_https;
            return(verify_basic_auth($config, $basic_auth, $login));
        }
    }
    printf(STDERR "thruk_auth: basic auth code: %d\n", $res->code) if ($ENV{'THRUK_COOKIE_AUTH_VERBOSE'} && $ENV{'THRUK_COOKIE_AUTH_VERBOSE'} > 2);
    if($res->code == 200 and $res->decoded_content =~ m/^OK:\ (.*)$/mx) {
        if($1 eq Thruk::Authentication::User::transform_username($config, $login)) {
            return 1;
        }
    }
    printf(STDERR "thruk_auth: basic auth result: %s\n", $res->decoded_content) if ($ENV{'THRUK_COOKIE_AUTH_VERBOSE'} && $ENV{'THRUK_COOKIE_AUTH_VERBOSE'} > 3);
    if($res->code == 500 and $res->decoded_content =~ m/\Qtimeout during auth check\E/mx) {
        return -1;
    }
    return 0;
}

##############################################

=head2 get_user_agent

    get_user_agent($config)

returns user agent used for external requests

=cut
sub get_user_agent {
    my($config) = @_;
    my $ua = Thruk::UserAgent->new($config);
    $ua->timeout(30);
    $ua->agent("thruk_auth");
    $ua->no_proxy('127.0.0.1', 'localhost');
    $ua->ssl_opts('SSL_ca_path' => $config->{ssl_ca_path} || "/etc/ssl/certs");
    return $ua;
}

##############################################

=head2 clean_session_files

    clean_session_files($c)

clean up session files

=cut
sub clean_session_files {
    my($c) = @_;
    die("no config") unless $c;
    my $sdir    = $c->config->{'var_path'}.'/sessions';
    my $cookie_auth_session_timeout = $c->config->{'cookie_auth_session_timeout'};
    if($cookie_auth_session_timeout <= 0) {
        # clean old unused sessions after one year, even if they don't expire
        $cookie_auth_session_timeout = 365 * 86400;
    }
    my $timeout = time() - $cookie_auth_session_timeout;
    my $fake_session_timeout = time() - 600;
    Thruk::Utils::IO::mkdir($sdir);
    my $sessions_by_user = {};
    opendir( my $dh, $sdir) or die "can't opendir '$sdir': $!";
    for my $entry (readdir($dh)) {
        next if $entry eq '.' or $entry eq '..';
        my $file = $sdir.'/'.$entry;
        my($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
           $atime,$mtime,$ctime,$blksize,$blocks) = stat($file);
        if($mtime) {
            if($mtime < $timeout) {
                unlink($file);
            }
            elsif($mtime < $fake_session_timeout) {
                eval {
                    my $data = Thruk::Utils::IO::json_lock_retrieve($file);
                    if($data && $data->{'fake'}) {
                        unlink($file);
                    } else {
                        $sessions_by_user->{$data->{'username'}}->{$file} = $mtime;
                    }
                };
            }
        }
    }

    # limit sessions to 500 per user
    my $max_sessions_per_user = 500;
    for my $user (sort keys %{$sessions_by_user}) {
        my $user_sessions = $sessions_by_user->{$user};
        my $num = scalar keys %{$user_sessions};
        if($num > $max_sessions_per_user) {
            $c->log->warn(sprintf("user %s has %d open sessions (max. %d) cleaning up.", $user, $num, $max_sessions_per_user));
            for my $file (reverse sort { $user_sessions->{$b} <=> $user_sessions->{$a} } keys %{$user_sessions}) {
                if($num > $max_sessions_per_user) {
                    unlink($file);
                    $num--;
                } else {
                    last;
                }
            }
        }
    }

    return;
}

##############################################

=head2 get_netloc

    get_netloc($url)

return netloc used by LWP::UserAgent credentials

=cut
sub get_netloc {
    my($url) = @_;
    if($url =~ m/^(http|https):\/\/([^\/:]+)\//mx) {
        my $port = $1 eq 'https' ? 443 : 80;
        my $host = $2;
        $host = $host.':'.$port;
        return($host);
    }
    if($url =~ m/^(http|https):\/\/([^\/:]+):(\d+)\//mx) {
        my $port = $3;
        my $host = $2;
        $host = $host.':'.$port unless CORE::index($host, ':') != -1;
        return($host);
    }
    return('localhost:80');
}

##############################################

=head2 store_session

  store_session($config, $sessionid, $data)

store session data

=cut

sub store_session {
    my($config, $sessionid, $data) = @_;

    # store session key hashed
    my($hashed_key, $type);
    ($sessionid,$hashed_key,$type) = generate_sessionid($sessionid);

    $data->{'csrf_token'} = _generate_csrf_token([$sessionid]) unless $data->{'csrf_token'};
    delete $data->{'private_key'};
    my $hash_raw = delete $data->{'hash_raw'};

    confess("no username") unless $data->{'username'};

    # store basic auth hash crypted with the private session id
    if($data->{'hash'} && $data->{'hash'} ne 'none') {
        if($hash_raw) {
            # no need to recrypt every time
            $data->{'hash'} = $hash_raw;
        } else {
            my $key = substr(_null_padding($sessionid,32,'e'),0,32);
            my $cipher = Crypt::Rijndael->new($key, Crypt::Rijndael::MODE_CBC);
            $data->{'hash'} = "CBC,".MIME::Base64::encode_base64($cipher->encrypt(_null_padding($data->{'hash'},32,'e')));
        }
    }

    my $sdir = $config->{'var_path'}.'/sessions';
    die("only letters and numbers allowed") if $sessionid !~ m/^[a-z0-9_]+$/mx;
    my $sessionfile = $sdir.'/'.$hashed_key.'.'.$type;
    Thruk::Utils::IO::mkdir_r($sdir);
    Thruk::Utils::IO::json_lock_store($sessionfile, $data);

    # restore some keys which should not be stored
    $data->{'private_key'} = $sessionid;
    $data->{'hash_raw'} = $hash_raw if $hash_raw;

    return($sessionid, $sessionfile, $data);
}

##############################################

=head2 retrieve_session

  retrieve_session(file => $sessionfile, config => $config)
  retrieve_session(id   => $sessionid,   config => $config)

returns session data as hash

    {
        id       => session id (if known),
        file     => session data file name,
        username => login name,
        active   => timestamp of last activity
        address  => remote address of user (optional)
        hash     => login hash from basic auth (optional)
        roles    => extra session roles (optional)
    }

=cut

sub retrieve_session {
    my(%args) = @_;
    my($sessionfile, $sessionid);
    my $config = $args{'config'} or confess("missing config");
    my($type, $hashed_key);
    if($args{'file'}) {
        $sessionfile = Thruk::Utils::basename($args{'file'});
        # REMOVE AFTER: 01.01.2020
        if($sessionfile =~ $hashed_key_file_regex) {
            $hashed_key = $1;
            $type       = substr($2, 1) if $2;
        } else {
            return;
        }
        if(!$type && length($hashed_key) < 64) {
            my($new_hashed_key, $newfile) = _upgrade_session_file($config, $hashed_key);
            if($newfile) {
                $sessionfile = Thruk::Utils::basename($newfile);
                $type        = $supported_digests->{$default_digest};
                $hashed_key  = $new_hashed_key;
            }
        }
    } else {
        my $nr;
        $sessionid = $args{'id'};
        if($sessionid =~ $session_key_regex) {
            $nr = substr($2, 1) if $2;
        } else {
            return;
        }
        if(!$nr) {
            # REMOVE AFTER: 01.01.2020
            if(length($sessionid) < 64) {
                _upgrade_session_file($config, $sessionid);
                $nr = $default_digest;
            }
            # /REMOVE AFTER
            else {
                return;
            }
        }
        $type = $supported_digests->{$nr};
    }
    return unless $type;

    if(!$hashed_key) {
        my $digest = Digest->new($type);
        $digest->add($sessionid);
        $hashed_key = $digest->hexdigest();
    }
    my $sdir = $config->{'var_path'}.'/sessions';
    $sessionfile = $sdir.'/'.$hashed_key.'.'.$type;

    my $data;
    return unless -e $sessionfile;
    my @stat = stat(_);
    eval {
        $data = Thruk::Utils::IO::json_lock_retrieve($sessionfile);
    };
    # REMOVE AFTER: 01.01.2020
    if(!$data) {
        my $raw = scalar read_file($sessionfile);
        chomp($raw);
        my($auth,$ip,$username,$roles) = split(/~~~/mx, $raw, 4);
        return unless defined $username;
        my @roles = defined $roles ? split(/,/mx,$roles) : ();
        $data = {
            address  => $ip,
            username => $username,
            hash     => $auth,
            roles    => \@roles,
        };
    }
    # /REMOVE
    return unless defined $data;
    if($sessionid && $data->{hash} && $data->{hash} =~ m/^CBC,(.*)$/mx) {
        my $crypted = $1;
        $data->{hash_raw} = $data->{hash};
        # decrypt from private key
        my $key = substr(_null_padding($sessionid,32,'e'),0,32);
        my $cipher = Crypt::Rijndael->new($key, Crypt::Rijndael::MODE_CBC);
        $data->{hash} = _null_padding($cipher->decrypt(MIME::Base64::decode_base64($crypted)), 32, 'd');
    }
    $data->{file}        = $sessionfile;
    $data->{hashed_key}  = $hashed_key;
    $data->{digest}      = $type;
    $data->{active}      = $stat[9];
    $data->{roles}       = [] unless $data->{roles};
    $data->{private_key} = $sessionid if $sessionid;
    return($data);
}

##############################################
sub _generate_csrf_token {
    my($salt) = @_;
    my $type = $supported_digests->{$default_digest};
    my $digest = Digest->new($type);
    $digest->add(time());
    $digest->add(rand(10000));
    if($salt) {
        for my $s (@{$salt}) {
            $digest->add($s);
        }
    }
    return($digest->hexdigest());
}

##############################################
# migrate session from old md5hex to current format
# REMOVE AFTER: 01.01.2020
sub _upgrade_session_file {
    my($config, $sessionid) = @_;
    my $folder = $config->{'var_path'}.'/sessions';
    return unless -e $folder.'/'.$sessionid;
    my $type   = $supported_digests->{$default_digest};
    my $digest = Digest->new($type);
    $digest->add($sessionid);
    my $hashed_key = $digest->hexdigest();
    my $newfile = $folder.'/'.$hashed_key.'.'.$type;
    move($folder.'/'.$sessionid, $newfile);
    return($hashed_key, $newfile);
}

##############################################
sub _null_padding {
    my($block,$bs,$decrypt) = @_;
    return unless length $block;
    $block = length $block ? $block : '';
    if ($decrypt eq 'd') {
        $block=~ s/\0*$//mxs;
        return $block;
    }
    return $block . pack("C*", (0) x ($bs - length($block) % $bs));
}

##############################################

=head2 generate_sessionid

  generate_sessionid([$sessionid])

returns random sessionid along with the hashed key and the hash type

    returns $sessionid, $hashed_key, $type

=cut

sub generate_sessionid {
    my($sessionid) = @_;
    my $type = $supported_digests->{$default_digest};
    my $digest = Digest->new($type);
    if(!$sessionid) {
        $digest->add(rand(1000000));
        $digest->add(time());
        $sessionid = $digest->hexdigest()."_".$default_digest;
        if(length($sessionid) != 66) { die("creating session id failed.") }
        $digest->reset();
    }
    $digest->add($sessionid);
    my $hashed_key = $digest->hexdigest();
    return($sessionid, $hashed_key, $type);
}

1;
