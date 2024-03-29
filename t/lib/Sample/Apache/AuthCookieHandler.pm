package Sample::Apache::AuthCookieHandler;
use strict;
use Apache;
use Apache::Constants qw(:common);
use Apache::AuthCookie;
use vars qw(@ISA);

@ISA = qw(Apache::AuthCookie);

sub authen_cred ($$\@) {
    my $self = shift;
    my $r = shift;
    my @creds = @_;

    return if $creds[0] eq 'fail'; # simulate bad_credentials

    # This would really authenticate the credentials 
    # and return the session key.
    # Here I'm just using setting the session
    # key to the credentials and delaying authentication.
    #
    # Similar to HTTP Basic Authentication, only not base 64 encoded
    join(":", @creds);
}

sub authen_ses_key ($$$) {
    my $self = shift;
    my $r = shift;
    my($user, $password) = split(/:/, shift, 2);

    if ($user eq 'programmer' && $password eq 'Hero') {
        return $user;
    }
    elsif ($user eq 'some-user') {
        return $user;
    }
    elsif ($user eq '0') {
        return $user;
    }

    return;
}

sub dwarf {
    my $self = shift;
    my $r = shift;

    my $user = $r->connection->user;
    if ("bashful doc dopey grumpy happy sleepy sneezy programmer"
	=~ /\b$user\b/) {
	# You might be thinking to yourself that there were only 7
	# dwarves, that's because the marketing folks left out
	# the often under appreciated "programmer" because:
	#
	# 10) He didn't hold 8 to 5 hours.
	# 9)  Sometimes forgot to shave several days at a time.
	# 8)  Was always buzzed on caffine.
	# 7)  Wasn't into heavy labor.
	# 6)  Prone to "swearing while he worked."
	# 5)  Wasn't as easily controlled as the other dwarves.
	# 
	# 1)  He posted naked pictures of Snow White to the Internet.
	return OK;
    }

    return FORBIDDEN;
}

1;
