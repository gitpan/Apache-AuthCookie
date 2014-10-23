package Apache::AuthCookie;
use strict;
use mod_perl qw(1.07 StackedHandlers MethodHandlers Authen Authz);
use Apache::Constants qw(:common M_GET M_POST AUTH_REQUIRED REDIRECT);
use vars qw($VERSION);

# $Id: AuthCookie.pm,v 2.2 2000/03/14 17:46:42 ken Exp $
$VERSION = sprintf '%d.%03d', q$Revision: 2.2 $ =~ /: (\d+).(\d+)/;

sub recognize_user ($$) {
  my ($self, $r) = @_;
  my $debug = $r->dir_config("AuthCookieDebug") || 0;
  my ($auth_type, $auth_name) = ($r->auth_type, $r->auth_name);
  return unless $auth_type && $auth_name;
  return unless $r->header_in('Cookie');

  my ($cookie) = $r->header_in('Cookie') =~ /${auth_type}_${auth_name}=([^;]+)/;
  $r->log_error("cookie ${auth_type}_${auth_name} is $cookie") if $debug >= 2;
  if (my ($user) = $auth_type->authen_ses_key($r, $cookie)) {
    $r->log_error("user is $user") if $debug >= 2;
    $r->connection->user($user);
  }
}


sub login ($$) {
  my ($self, $r) = @_;
  my $debug = $r->dir_config("AuthCookieDebug") || 0;

  my ($auth_type, $auth_name) = ($r->auth_type, $r->auth_name);
  my %args = $r->method eq 'POST' ? $r->content : $r->args;
  unless (exists $args{'destination'}) {
    $r->log_error("No key 'destination' found in posted data");
    return SERVER_ERROR;
  }
  
  # Get the credentials from the data posted by the client
  my @credentials;
  while (exists $args{"credential_" . ($#credentials + 1)}) {
    $r->log_error("credential_" . ($#credentials + 1) . " " .
		  $args{"credential_" . ($#credentials + 1)}) if ($debug >= 2);
    push(@credentials, $args{"credential_" . ($#credentials + 1)});
  }
  
  # Exchange the credentials for a session key.
  my $ses_key = $self->authen_cred($r, @credentials);
  $r->log_error("ses_key " . $ses_key) if ($debug >= 2);

  # Send the Set-Cookie header.
  $r->err_header_out("Set-Cookie" => $self->_cookie_string($r, "$auth_type\_$auth_name", $ses_key));

  if ($r->method eq 'POST') {
    $r->method('GET');
    $r->method_number(M_GET);
    $r->headers_in->unset('Content-Length');
  }
  $r->no_cache(1);
  $r->err_header_out("Pragma" => "no-cache");
  $r->header_out("Location" => $args{'destination'});
  return REDIRECT;
}

sub logout($$) {
  my ($self,$r) = @_;
  my $debug = $r->dir_config("AuthCookieDebug") || 0;
  
  my ($auth_type, $auth_name) = ($r->auth_type, $r->auth_name);
  
  # Send the Set-Cookie header to expire the auth cookie.
  my $str = $self->_cookie_string($r, "$auth_type\_$auth_name", '');
  $r->err_header_out("Set-Cookie" => "$str; expires=Mon, 21-May-1971 00:00:00 GMT");
  $r->log_error("set_cookie " . $r->err_header_out("Set-Cookie")) if $debug >= 2;
  $r->no_cache(1);
  $r->err_header_out("Pragma" => "no-cache");

  #my %args = $r->args;
  #if (exists $args{'redirect'}) {
  #  $r->header_out("Location" => $args{'redirect'});
  #  return REDIRECT;
  #} else {
  #  $r->status(200);
  #  return OK;
  #}
}

sub authenticate ($$) {
  my ($auth_type, $r) = @_;
  my ($authen_script, $auth_user);
  my $debug = $r->dir_config("AuthCookieDebug") || 0;
  
  $r->log_error("auth_type " . $auth_type) if ($debug >= 3);
  return OK unless $r->is_initial_req; # Only authenticate the first internal request
  
  if ($r->auth_type ne $auth_type) {
    # This location requires authentication because we are being called,
    # but we don't handle this AuthType.
    $r->log_error("AuthType mismatch: $auth_type =/= ".$r->auth_type) if $debug >= 3;
    return DECLINED;
  }

  # Ok, the AuthType is $auth_type which we handle, what's the authentication
  # realm's name?
  my $auth_name = $r->auth_name;
  $r->log_error("auth_name " . $auth_name) if $debug >= 2;
  unless ($auth_name) {
    $r->log_reason("AuthName not set, AuthType=$auth_type", $r->uri);
    return SERVER_ERROR;
  }

  # Get the Cookie header. If there is a session key for this realm, strip
  # off everything but the value of the cookie.
  my ($ses_key_cookie) = ($r->header_in("Cookie") || "") =~ /$auth_type\_$auth_name=([^;]+)/;
  $ses_key_cookie = "" unless defined($ses_key_cookie);

  $r->log_error("ses_key_cookie " . $ses_key_cookie) if ($debug >= 1);
  $r->log_error("uri " . $r->uri) if ($debug >= 2);

  if ($ses_key_cookie) {
    if ($auth_user = $auth_type->authen_ses_key($r, $ses_key_cookie)) {
      # We have a valid session key, so we return with an OK value.
      # Tell the rest of Apache what the authentication method and
      # user is.

      $r->no_cache(1);
      $r->err_header_out("Pragma", "no-cache");
      $r->connection->auth_type($auth_type);
      $r->connection->user($auth_user);
      $r->log_error("user authenticated as $auth_user")	if $debug >= 1;
      return OK;
    } else {
      # There was a session key set, but it's invalid for some reason. So,
      # remove it from the client now so when the credential data is posted
      # we act just like it's a new session starting.
      
      my $str = $auth_type->_cookie_string($r, "$auth_type\_$auth_name", '');
      $r->err_header_out("Set-Cookie" => "$str; expires=Mon, 21-May-1971 00:00:00 GMT");
      $r->log_error("set_cookie " . $r->err_header_out("Set-Cookie"))
	if $debug >= 2;
    }
  }

  # They aren't authenticated, and they tried to get a protected
  # document. Send them the authen form.  There should be a
  # PerlSetVar directive that give us the name and location of the
  # script to execute for the authen page.
  
  unless ($authen_script = $r->dir_config($auth_name . "LoginScript")) {
    $r->log_reason($auth_type . 
		   "::Auth:authen authentication script not set for auth realm " .
		   $auth_name, $r->uri);
    return SERVER_ERROR;
  }
  $r->custom_response(AUTH_REQUIRED, $authen_script);
  
  return AUTH_REQUIRED;
}

sub _cookie_string {
  shift;
  my ($r, $key, $val) = @_;

  my $string = "$key=$val";

  my $auth_name = $r->auth_name;
  if (my $path = $r->dir_config("${auth_name}Path")) {
    $string .= "; path=$path";
  }
  #$r->log_error("Attribute ${auth_name}Path not set") unless $path;

  if (my $domain = $r->dir_config("${auth_name}Domain")) {
    $string .= "; domain=$domain";
  }

  return $string;
}

sub authorize ($$) {
  my ($auth_type, $r) = @_;
  my $debug = $r->dir_config("AuthCookieDebug") || 0;
  
  return OK unless $r->is_initial_req; #only the first internal request
  
  if ($r->auth_type ne $auth_type) {
    $r->log_error($auth_type . " auth type is " .
		  $r->auth_type) if ($debug >= 3);
    return DECLINED;
  }
  
  my $reqs_arr = $r->requires or return DECLINED;
  
  my $user = $r->connection->user;
  unless ($user) {
    # user is either undef or =0 which means the authentication failed
    $r->log_reason("No user authenticated", $r->uri);
    return FORBIDDEN;
  }
  
  my ($forbidden);
  foreach my $req (@$reqs_arr) {
    my ($requirement, $args) = split /\s+/, $req->{requirement}, 2;
    $args = '' unless defined $args;
    $r->log_error("requirement := $requirement, $args") if $debug >= 2;
    
    next if $requirement eq 'valid-user';
    next if $requirement eq 'user' and $args =~ m/\b$user\b/;

    # Call a custom method
    my $ret_val = $auth_type->$requirement($r, $args);
    $r->log_error("$auth_type->$requirement returned $ret_val") if $debug >= 3;
    next if $ret_val == OK;

    # Nothing succeeded, deny access to this user.
    $forbidden = 1;
    last;
  }

  return $forbidden ? FORBIDDEN : OK;
}


sub authen ($$) {
    my $that = shift;
    my $r = shift;
    my($ses_key_cookie, $cookie_path, $authen_script);
    my($auth_user, $auth_name, $auth_type, $ses_key);

    my $debug = $r->dir_config("AuthCookieDebug") || 0;

    $r->log_error("that " . $that) if ($debug >= 3);
    #only the first internal request
    return OK unless $r->is_initial_req;

    ($auth_type) = ($that =~ /^([^:]+)/);
    $r->log_error("auth_type " . $auth_type) if ($debug >= 2);

    if ($r->auth_type ne $auth_type)
    {
	# This location requires authentication because we are being called,
	# but we don't handle this AuthType.
	$r->log_error($auth_type . "::Auth:authen auth type is " .
	$r->auth_type) if ($debug >= 3);
	return DECLINED;
    }

    # Ok, the AuthType is $auth_type which we handle, what's the authentication
    # realm's name?
    $auth_name = $r->auth_name;
    $r->log_error("auth_name " . $auth_name) if ($debug >= 2);
    if (!($auth_name))
    {
	$r->log_reason($auth_type . "::Auth:authen need AuthName ", $r->uri);
	return SERVER_ERROR;
    }

    # There should also be a PerlSetVar directive that give us the path
    # to set in Set-Cookie header for this realm.
    $cookie_path = $r->dir_config($auth_name . "Path");
    if (!($cookie_path)) {
	$r->log_reason($auth_type . "::Auth:authen path not set for " .
	    "auth realm " .  $auth_name, $r->uri);
	return SERVER_ERROR;
    }


    # Get the Cookie header. If there is a session key for this realm, strip
    # off everything but the value of the cookie.
    ($ses_key_cookie) = ( ($r->header_in("Cookie") || "") =~ 
	/${auth_type}_${auth_name}=([^;]+)/);
    $ses_key_cookie = "" unless defined($ses_key_cookie);
    $ses_key = $ses_key_cookie;

    $r->log_error("ses_key_cookie " . $ses_key_cookie) if ($debug >= 1);
    $r->log_error("cookie_path " . $cookie_path) if ($debug >= 2);
    $r->log_error("uri " . $r->uri) if ($debug >= 2);

    if (! $ses_key_cookie && defined($r->args))
    {
	# No session key set, but the method is post. We should be
	# coming back with the users credentials.

	# If not, we are eating up the posted content so the
	# user will be SOL
	my %args = $r->args;
	if ($args{'AuthName'} ne $auth_name ||
	    $args{'AuthType'} ne $r->auth_type)
	{
	    $r->log_reason($auth_type . "::Auth:authen credentials are " .
		"not for this realm", $r->uri);
	    return SERVER_ERROR;
	}

	# Get the credentials from the data posted by the client
	my @credentials;
	while ($args{"credential_" . ($#credentials + 1)})
	{
	    $r->log_error("credential_" . ($#credentials + 1) . " " .
	    $args{"credential_" . ($#credentials + 1)}) if ($debug >= 2);
	    push(@credentials, $args{"credential_" . ($#credentials + 1)});
	}

	# Exchange the credentials for a session key. If they credentials
	# fail this should return nothing, which will fall trough to call
	# the get credentials script again
	$ses_key = $that->authen_cred($r, @credentials);
	$r->log_error("ses_key " . $ses_key) if ($debug >= 2);
    }
    elsif (! $ses_key_cookie && $r->method_number != M_GET)
    {
	# They aren't authenticated, but they are trying a POST or
	# something, this is not allowed.
	$r->log_reason($auth_type . "::Auth:authen auth header is not set " .
	     "and method is not GET ", $r->uri);
	return SERVER_ERROR;
    }

    if ($ses_key) {
	# We have a session key. So, lets see if it's valid. If it is
	# we return with an OK value. If not then we fall through to
	# call the get credentials script.
	if ($auth_user = $that->authen_ses_key($r, $ses_key)) {
	    if (!($ses_key_cookie)) {
		# They session key is valid, but it's not yet set on
		# the client. So, send the Set-Cookie header.
		$r->err_header_out("Set-Cookie" => $auth_type . "_" .
		    $auth_name .  "=" . $ses_key . "; path=" .  $cookie_path);
		$r->log_error("set_cookie " . $r->err_header_out("Set-Cookie"))
		    if ($debug >= 2);

		# Redirect the client to the same page, but without the
		# query string in the URL. This forces the
		# client to reload the page and keeps it
		# from displaying the credentials in the "Location".
		$r->no_cache(1);
                $r->err_header_out("Pragma", "no-cache");
                $r->header_out("Location" => $r->uri);
                return REDIRECT;
	    }
	    # Tell the rest of Apache what the authentication method and
	    # user is.
	    $r->no_cache(1);
	    $r->err_header_out("Pragma", "no-cache");
	    $r->connection->auth_type($auth_type);
	    $r->connection->user($auth_user);
	    $r->log_error("user authenticated as " . $auth_user)
		if ($debug >= 1);
	    return OK;
	}
    }

    # There was a session key set, but it's invalid for some reason. So,
    # remove it from the client now so when the credential data is posted
    # we act just like it's a new session starting.
    if ($ses_key_cookie) {
	$r->err_header_out("Set-Cookie" => $auth_type . "_" . $auth_name .
	    "=; path=" .  $cookie_path .
	    "; expires=Mon, 21-May-1971 00:00:00 GMT");
	$r->log_error("set_cookie " . $r->err_header_out("Set-Cookie"))
	    if ($debug >= 2);
    }

    # They aren't authenticated, and they tried to get a protected
    # document. Send them the authen form.

    if (defined($r->args)) {
	# Redirect the client to the same page, but without the
	# query string in the URL. This forces the
	# client to reload the page and keeps it
	# from displaying the credentials in the "Location".
	$r->err_header_out("Pragma", "no-cache");
	$r->header_out("Location" => $r->uri);
	return REDIRECT;
    } else {
	# There should also be a PerlSetVar directive that give us the name
	# and location of the script to execute for the authen page.
	$authen_script = $r->dir_config($auth_name . "LoginScript")
	    || "";
	if (!($authen_script)) {
	    $r->log_reason($auth_type . 
		"::Auth:authen authentication script not set for auth realm " .
		$auth_name, $r->uri);
	    return SERVER_ERROR;
	}
	$r->custom_response(AUTH_REQUIRED, $authen_script);

	return AUTH_REQUIRED;
    }
}

sub authz ($$) {
    my $that = shift;
    my $r = shift;
    my($auth_name, $auth_type);

    my $debug = $r->dir_config("AuthCookieDebug") || 0;

    return OK unless $r->is_initial_req; #only the first internal request

    ($auth_type) = ($that =~ /^([^:]+)/);

    if ($r->auth_type ne $auth_type) {
	$r->log_error($auth_type . "::Auth:authz auth type is " .
	    $r->auth_type) if ($debug >= 3);
	return DECLINED;
    }

    my $reqs_arr = ($r->requires || "");
    return OK unless $reqs_arr;

    my $user = $r->connection->user;
    if (!($user)) {
	# user is either undef or =0 which means the authentication failed
	$r->log_reason("No user authenticated", $r->uri);
	return FORBIDDEN;
    }

    my($reqs, $requirement, $args, $restricted);
    foreach $reqs (@$reqs_arr) {
        ($requirement, $args) = split /\s+/, $reqs->{requirement}, 2;
	$args = "" unless defined($args);
	$r->log_error("requirement := $requirement, $args") if ($debug >= 2);

	if ($requirement eq "valid-user") {
	    return OK;
	} elsif ($requirement eq "user") {
	    return OK if ($args =~ m/\b$user\b/);
	} else {
	    my $req_method;
	    if ($req_method = $that->can($requirement)) {
		my $ret_val = &$req_method($that, $r, $args);
		 $r->log_error($that . 
		   " called requirement method " . $requirement . 
		   " which returned " . $ret_val) if ($debug >= 3);
		return OK if ($ret_val == OK);
	    } else {
		$r->log_error($that . 
		    " tried to call undefined requirement method " .
		    $requirement);
	    }
	}
        $restricted++;
    }

    return OK unless $restricted;
    return FORBIDDEN;
}

1;
__END__

=head1 NAME

Apache::AuthCookie - Perl Authentication and Authorization via cookies

=head1 SYNOPSIS

C<use mod_perl qw(1.07 StackedHandlers MethodHandlers Authen Authz);>

=for html
<PRE>
=end html

 # In httpd.conf or .htaccess:
 PerlModule Sample::AuthCookieHandler
 PerlSetVar WhatEverPath /
 PerlSetVar WhatEverLoginScript /login.pl

 # These documents require user to be logged in.
 <Location /protected>
  AuthType Sample
  AuthName WhatEver
  PerlAuthenHandler Sample::AuthCookieHandler->authenticate
  PerlAuthzHandler Sample::AuthCookieHandler->authorize
  require valid-user
 </Location>

 # These documents don't require logging in, but allow it.
 <FilesMatch "\.ok$">
  AuthType Sample
  AuthName WhatEver
  PerlFixupHandler Sample::AuthCookieHandler->recognize_user
 </FilesMatch>

 # This is the action of the login.pl script above.
 <Files LOGIN>
  AuthType Sample
  AuthName WhatEver
  SetHandler perl-script
  PerlHandler Sample::AuthCookieHandler->login
 </Files>


=for html
</PRE>
=end html

=head1 DESCRIPTION

B<Apache::AuthCookie> allows you to intercept a user's first
unauthenticated access to a protected document. The user will be
presented with a custom form where they can enter authentication
credentials. The credentials are posted to the server where AuthCookie
verifies them and returns a session key.

The session key is returned to the user's browser as a cookie. As a
cookie, the browser will pass the session key on every subsequent
accesses. AuthCookie will verify the session key and re-authenticate
the user.

All you have to do is write a custom module that inherits from
AuthCookie.  Your module implements two functions:

=over 4

=item C<authen_cred()>

Verify the user-supplied credentials and return a session key.  The
session key can be any string - often you'll use some string
containing username, timeout info, and any other information you need
to determine access to documents, and append a one-way hash of those
values together with some secret key.

=item C<authen_ses_key()>

Verify the session key (previously generated by C<authen_cred()>,
possibly during a previous request) and return the user ID.  This user
ID will be fed to C<$r-E<gt>connection-E<gt>user()> to set Apache's
idea of who's logged in.

=back

By using AuthCookie versus Apache's built-in AuthBasic you can design
your own authentication system.  There are at least three main
benefits.

=over 4

=item 1.

The client doesn't *have* to pass the user credentials on every
subsequent access.  If you're using passwords, this means that the
password can be sent on the first request only, and subsequent
requests don't need to send this (potentially sensitive) information.
This is known as "ticket-based" authentication.

=item 2.

When you determine that the client should stop using the
credentials/session key, the server can tell the client to delete the
cookie.  Letting users "log out" is a notoriously impossible-to-solve
problem of AuthBasic.

=item 3.

AuthBasic dialog boxes are ugly.  You can design your own HTML login
forms when you use AuthCookie.

=back

This is the flow of the authentication handler, less the details of the
redirects. Two REDIRECT's are used to keep the client from displaying
the user's credentials in the Location field. They don't really change
AuthCookie's model, but they do add another round-trip request to the
client.

=for html
<PRE>

 (-----------------------)     +---------------------------------+
 ( Request a protected   )     | AuthCookie sets custom error    |
 ( page, but user hasn't )---->| document and returns            |
 ( authenticated (no     )     | AUTH_REQUIRED. Apache abandons  |      
 ( session key cookie)   )     | current request and creates sub |      
 (-----------------------)     | request for the error document. |<-+
                               | Error document is a script that |  |
                               | generates a form where the user |  |
                 return        | enters authentication           |  |
          ^------------------->| credentials (login & password). |  |
         / \      False        +---------------------------------+  |
        /   \                                   |                   |
       /     \                                  |                   |
      /       \                                 V                   |
     /         \               +---------------------------------+  |
    /   Pass    \              | User's client submits this form |  |
   /   user's    \             | to the LOGIN URL, which calls   |  |
   | credentials |<------------| AuthCookie->login().            |  |
   \     to      /             +---------------------------------+  |
    \authen_cred/                                                   |
     \ function/                                                    |
      \       /                                                     |
       \     /                                                      |
        \   /            +------------------------------------+     |
         \ /   return    | Authen cred returns a session      |  +--+
          V------------->| key which is opaque to AuthCookie.*|  |
                True     +------------------------------------+  |
                                              |                  |
               +--------------------+         |      +---------------+
               |                    |         |      | If we had a   |
               V                    |         V      | cookie, add   |
  +----------------------------+  r |         ^      | a Set-Cookie  |
  | If we didn't have a session|  e |T       / \     | header to     |
  | key cookie, add a          |  t |r      /   \    | override the  |
  | Set-Cookie header with this|  u |u     /     \   | invalid cookie|
  | session key. Client then   |  r |e    /       \  +---------------+
  | returns session key with   |  n |    /  pass   \               ^    
  | sucsesive requests         |    |   /  session  \              |    
  +----------------------------+    |  /   key to    \    return   |
               |                    +-| authen_ses_key|------------+
               V                       \             /     False
  +-----------------------------------+ \           /
  | Tell Apache to set Expires header,|  \         /
  | set no-cache Pragma header, set   |   \       /
  | user to user ID returned by       |    \     /
  | authen_ses_key, set authentication|     \   /
  | to our type (e.g. AuthCookie).    |      \ /
  +-----------------------------------+       V
         (---------------------)              ^
         ( Request a protected )              |
         ( page, user has a    )--------------+
         ( session key cookie  )
         (---------------------)


 *  The session key that the client gets can be anything you want.  For
    example, encrypted information about the user, a hash of the
    username and password (similar in function to Digest
    authentication), or the user name and password in plain text
    (similar in function to HTTP Basic authentication).

    The only requirement is that the authen_ses_key function that you
    create must be able to determine if this session_key is valid and
    map it back to the originally authenticated user ID.

=for html
</PRE>

=head1 UPGRADING FROM VERSION 1.4

There are a few interface changes that you need to be aware of
when migrating from version 1.x to 2.x.  First, the authen() and
authz() methods are now deprecated, replaced by the new authenticate()
and authorize() methods.  The old methods will go away in a couple
versions, but are maintained intact in this version to ease the task
of upgrading.  The use of these methods is essentially the same, though.

Second, when you change to the new method names (see previous
paragraph), you must change the action of your login forms to the
location /LOGIN (or whatever URL will call your module's login()
method).  You may also want to change their METHOD to POST instead of
GET, since that's much safer and nicer to look at (but you can leave
it as GET if you bloody well want to, for some god-unknown reason).

Third, you must change your login forms (see L<THE LOGIN SCRIPT>
below) to indicate how requests should be redirected after a
successful login.

Fourth, you might want to take advantage of the new C<logout()>
method, though you certainly don't have to.

=head1 EXAMPLE

For an example of how to use Apache::AuthCookie, you may want to check
out the test suite, which runs AuthCookie through a few of its paces.
The documents are located in t/eg/, and you may want to peruse
t/real.t to see the generated httpd.conf file (at the bottom of
real.t) and check out what requests it's making of the server (at the
top of real.t).

=head1 THE LOGIN SCRIPT

You will need to create a login script (called login.pl above) that
generates an HTML form for the user to fill out.  The following fields
must be present in the form:

=over 4

=item 1.

The ACTION of the form must be /LOGIN (or whatever you defined in your
server configuration, as in the SYNOPSIS section).

=item 2.

The various user input fields (username, passwords, etc.) must be
named 'credential_0', 'credential_1', etc. on the form.

=item 3.

You must define a form field called 'destination' that tells
AuthCookie where to redirect the request after successfully logging
in.  Typically this value is obtained from C<$r-E<gt>prev-E<gt>uri>.
See the login.pl script in t/eg/.

=back

=head1 THE LOGOUT SCRIPT

If you want to let users log themselves out (something that can't be
done using Basic Auth), you need to create a logout script.  For an
example, see t/eg/logout.pl.  Logout scripts may want to take
advantage of AuthCookie's C<logout()> method, which will set the
proper cookie headers in order to clear the user's cookie.

Note that if you don't necessarily trust your users, you can't count
on cookie deletion for logging out.  You'll have to expire some
server-side login information too.  AuthCookie doesn't do this for
you, you have to handle it yourself.

=head1 ABOUT SESSION KEYS

Unlike the sample AuthCookieHandler, you have you verify the user's
login and password in C<authen_cred()>, then you do something
like:

    my $date = localtime;
    my $ses_key = MD5->hexhash(join(';', $date, $PID, $PAC));

save C<$ses_key> along with the user's login, and return C<$ses_key>.

Now C<authen_ses_key()> looks up the C<$ses_key> passed to it and
returns the saved login.  I use Oracle to store the session key and
retrieve it later, see the ToDo section below for some other ideas.

=head1 KNOWN LIMITATIONS

If the first unauthenticated request is a POST, it will be changed to
a GET after the user fills out the login forms, and POSTed data will
be lost.

=head2 TO DO

=over 4

=item *

There ought to be a way to solve the GET/POST problems in the
LIMITATIONS section.  They both involve being able to change a request
back & forth between GET & POST.  The second problem also involves
being able to re-insert the POSTed content into the request stream after
the user authenticates.  If you knows of a way, please drop me a note.

It might be nice if the logout method could accept some parameters
that could make it easy to redirect the user to another URI, or
whatever.  I'd have to think about the options needed before I
implement anything, though.

=back

=head1 AUTHOR

Ken Williams, ken@forum.swarthmore.edu

Originally written by Eric Bartley, bartley@purdue.edu

=head1 SEE ALSO

L<perl(1)>, L<mod_perl(1)>, L<Apache(1)>.

=cut
