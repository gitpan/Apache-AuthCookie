package Apache2::AuthCookie::Params;
$Apache2::AuthCookie::Params::VERSION = '3.22';
# ABSTRACT: AuthCookie Params Driver for mod_perl 2.x

use strict;
use warnings;
use base 'Apache::AuthCookie::Params::Base';
use Class::Load qw(try_load_class load_class);

sub _new_instance {
    my ($class, $r) = @_;

    my $debug = $r->dir_config('AuthCookieDebug') || 0;

    my $obj;

    if (try_load_class('Apache2::Request')) {
        $r->server->log_error("params: using Apache2::Request") if $debug >= 3;

        return Apache2::Request->new($r);
    }
    else {
        load_class('CGI');

        $r->server->log_error("params: using CGI") if $debug >= 3;

        return CGI->new($r);
    }

    return;
}

1;

__END__

=pod

=head1 NAME

Apache2::AuthCookie::Params - AuthCookie Params Driver for mod_perl 2.x

=head1 VERSION

version 3.22

=head1 SYNOPSIS

 Internal Use Only!

=head1 DESCRIPTION

This class handles CGI form data for L<Apache2::AuthCookie>.  It will try to use
L<Apache2::Request> (from libapreq2) if it is available.  If not, it will fall
back to use L<CGI>.

=head1 SOURCE

The development version is on github at L<http://github.com/mschout/apache-authcookie>
and may be cloned from L<git://github.com/mschout/apache-authcookie.git>

=head1 BUGS

Please report any bugs or feature requests to bug-apache-authcookie@rt.cpan.org or through the web interface at:
 http://rt.cpan.org/Public/Dist/Display.html?Name=Apache-AuthCookie

=head1 AUTHOR

Michael Schout <mschout@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2000 by Ken Williams.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
