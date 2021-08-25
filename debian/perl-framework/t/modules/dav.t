use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestRequest;
use Apache::TestUtil;
use HTTP::Date;

##
## mod_dav tests
##

plan tests => 19, [qw(dav HTTP::DAV)];
require HTTP::DAV;

my $vars = Apache::Test::vars();
my $dav = HTTP::DAV->new;
my $server = "$vars->{servername}:$vars->{port}";

my $htdocs = Apache::Test::vars('documentroot');
my $response;
my $dir = "modules/dav";
my $uri = "/$dir/dav.html";
my $body = <<CONTENT;
<html>
    <body>
    <center>
        <h1>mod_dav test page</h1>
        this is a page generated by<br>
        the mod_dav test in the Apache<br>
        perl test suite.<br>
    </center>
    </body>
</html>
CONTENT

## make sure its clean before we begin ##
unlink "$htdocs$uri" if -e "$htdocs$uri";
mkdir "$htdocs/$dir", oct('755') unless -e "$htdocs/$dir";

Apache::TestUtil::t_chown("$htdocs/$dir");

## set up resource and lock it ##
my $resource = $dav->new_resource( -uri => "http://$server$uri");
$response = $resource->lock;
print "resource lock test:\n";
ok $response->is_success;

## write new resource ##
$response = $resource->put($body);
print "DAV put test:\n";
ok $response->is_success;

## get properties ##
## Wait until none of the returned time
## properties equals "now"
sleep(2);
$response = $resource->propfind;
print "getting DAV resource properties:\n";
ok $response->is_success;

my $createdate = $resource->get_property( "creationdate" );
my $lastmodified = $resource->get_property( "getlastmodified" );
my $now = HTTP::Date::time2str(time());
print "created:     $createdate\n";
print "modified:    $lastmodified\n";
print "now:         $now\n";
ok $createdate ne $now;
ok $createdate eq $lastmodified;

## should be locked ##
print "resource lock status test:\n";
ok $resource->is_locked;

## unlock ##
print "resource unlock test:\n";
$response = $resource->unlock;
ok $response->is_success;

## should be unlocked ##
print "resource lock status test:\n";
$response = $resource->is_locked;
ok !$resource->is_locked;

## verify new resource using regular http get ##
my $actual = GET_BODY $uri;
print "getting uri...\nexpect:\n->$body<-\ngot:\n->$actual<-\n";
ok $actual eq $body;


## testing with second dav client ##
my $d2 = HTTP::DAV->new;
my $r2 = $d2->new_resource( -uri => "http://$server$uri");

## put an unlocked resource (will work) ##
$response = $r2->get;
my $b2 = $r2->get_content;
$b2 =~ s#<h1>mod_dav test page</h1>#<h1>mod_dav test page take two</h1>#;

print "putting with 2nd dav client (on unlocked resource)\n";
$response = $r2->put($b2);
ok $response->is_success;

$actual = GET_BODY $uri;
print "getting new uri...\nexpect:\n->$b2<-\ngot:\n->$actual<-\n";
ok $actual eq $b2;

## client 1 locks, client 2 should not be able to lock ##
print "client 1 locking resource\n";
$response = $resource->lock
(
    -owner => 'mod_dav test client 1',
    -depth => 'Infinity',
    -scope => 'exclusive',
    -type => 'write',
    -timeout => 120
);
ok $response->is_success;

print "client 2 attempting to lock same resource\n";
$response = $r2->lock
(
    -owner => 'mod_dav test client 2',
    -depth => 'Infinity',
    -scope => 'exclusive',
    -type => 'write',
    -timeout => 120
);
ok !$response->is_success;

## client 2 should not be able to put because the resource is already locked by client 1 ##
$response = $r2->get;
my $b3 = $r2->get_content;
$b3 =~ s#mod_dav#f00#g;

print "client 2 attempting to put resource locked by client 1\n";
$response = $r2->put($b3);
ok !$response->is_success;

print "verifying all is well through http\n";
$actual = GET_BODY $uri;
print "getting new uri...\nexpect:\n->$b2<-\ngot:\n->$actual<-\n";
ok $actual ne $b3;
ok $actual eq $b2;

## delete resource ##
$response = $resource->forcefully_unlock_all; ## trusing this will work
$response = $resource->delete;
print "resource delete test:\n";
ok $response->is_success;

$actual = GET_RC $uri;
print "expect 404 not found got: $actual\n";
ok $actual == 404;

## PR 49825 ##
my $user_agent = $dav->get_user_agent;
# invalid content-range header
$user_agent->default_header('Content-Range' => 'bytes 1-a/44' );
$response = $resource->put($body);
$actual = $response->code;
print "PR 49825: expect 400 bad request got: $actual\n";
ok $actual == 400;
$user_agent->default_header('Content-Range' => undef);

## clean up ##
rmdir "$htdocs/$dir/.DAV" or print "warning: could not remove .DAV dir: $!";
rmdir "$htdocs/$dir" or print "warning: could not remove dav dir: $!";
