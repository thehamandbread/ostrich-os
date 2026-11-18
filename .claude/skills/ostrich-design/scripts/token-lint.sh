#!/usr/bin/env bash
# token-lint.sh [REPO]: the look's rules as one check (council 2026-11-05, M7). Fails (exit 1) on:
#   1. a size written as a number where a token exists (tools/icons/tokens.toml): a radius equal to a
#      radius token, padding/margin/spacing equal to a space token, min-width/min-height equal to
#      target_min. Use [[name]]; the stylesheet has to be a stylesheet.css.in so the build fills it.
#   2. a fixed hex colour in an extension stylesheet: use a {{name}} from palette.toml (translucent
#      neutral rgba() overlays are theme-neutral by design and are not checked).
#   3. a button or segment class (.ost-*-button, .ost-*-segment) with no :focus rule anywhere in the
#      stylesheets: key focus has to show (WCAG 2.4.7).
#   4. `dim-label` in tools/**/*.rs: deprecated since libadwaita 1.7, `dimmed` replaces it.
# An exception is written down, with its reason, in the stylesheet: `token-lint: allow <why>` on the
# line, or a block between `token-lint: off <why>` and `token-lint: on`. Needs bash, find and perl.
set -euo pipefail
REPO="${1:-$(git rev-parse --show-toplevel)}"
mapfile -t files < <(find "$REPO/modules/gnome/extensions" -name 'stylesheet.css' -o -name 'stylesheet.css.in' | sort)
mapfile -t rust < <(find "$REPO/tools" -name '*.rs' -not -path '*/target/*' | sort)
perl - "$REPO" "$REPO/tools/icons/tokens.toml" "${#files[@]}" "${files[@]}" "${rust[@]}" <<'PERL'
use strict;
use warnings;

my ($repo, $tokens, $nfiles, @rest) = @ARGV;
my @css = @rest[0 .. $nfiles - 1];
my @rs = @rest[$nfiles .. $#rest];

# Token values by kind.
my %kind = (radius => [], space => [], target => []);
open my $t, '<', $tokens or die "no $tokens";
while (<$t>) {
    next unless /^(radius|space|target_min)\w*\s*=\s*"(\d+)px"/;
    push @{$kind{$1 eq 'target_min' ? 'target' : $1}}, "$2px";
}
close $t;
my %re = map { my @v = @{$kind{$_}}; ($_ => @v ? '(?<![\d.\-])(?:' . join('|', @v) . ')(?![\d.])' : '(?!)') } keys %kind;

my $fail = 0;
sub report { my ($where, $msg) = @_; $where =~ s{^\Q$repo\E/}{}; print "FAIL $where: $msg\n"; $fail = 1; }

my $all = '';
for my $f (@css) {
    open my $h, '<', $f or die "$f: $!";
    my ($off, $inc) = (0, 0);
    my $n = 0;
    while (my $line = <$h>) {
        $n++;
        $all .= $line;
        if ($line =~ /token-lint: off/) { $off = 1; next }
        if ($off) { $off = 0 if $line =~ /token-lint: on/; next }
        next if $line =~ /token-lint: allow/;
        # Comments out (a comment can run over several lines).
        my $code = '';
        my $rest = $line;
        while (length $rest) {
            if ($inc) {
                if ($rest =~ s/^.*?\*\///s) { $inc = 0 } else { $rest = '' }
            } elsif ($rest =~ s/^(.*?)\/\*//s) {
                $code .= $1;
                $inc = 1;
            } else {
                $code .= $rest;
                $rest = '';
            }
        }
        next if $code =~ /^\s*$/;
        for my $decl (split /[;{}]/, $code) {
            next unless $decl =~ /^\s*([a-z-]+)\s*:\s*(.*?)\s*$/s;
            my ($prop, $val) = ($1, $2);
            my $k = $prop =~ /radius$/ ? 'radius'
                : $prop =~ /^(?:padding|margin)(?:-(?:top|bottom|left|right))?$|^spacing$|^-natural-hpadding$/ ? 'space'
                : $prop =~ /^min-(?:width|height)$/ ? 'target'
                : '';
            report("$f:$n", "$prop: $val (a token has this size: use [[name]]; a stylesheet.css.in is filled at build time)")
                if $k && $val =~ /$re{$k}/;
        }
        report("$f:$n", "a fixed colour ($1): use a {{name}} from palette.toml")
            if $code =~ /[:,(]\s*(#[0-9a-fA-F]{3,8})(?![0-9a-zA-Z])/;
    }
    close $h;
}

# Button and segment classes need a :focus rule somewhere in the stylesheets.
my %seen;
for my $f (@css) {
    open my $h, '<', $f or die;
    my ($off, $n) = (0, 0);
    while (my $line = <$h>) {
        $n++;
        if ($line =~ /token-lint: off/) { $off = 1; next }
        if ($off) { $off = 0 if $line =~ /token-lint: on/; next }
        next if $line =~ /token-lint: allow/ || $line =~ /^\s*\/?\*/;
        for my $c ($line =~ /\.(ost-[a-z0-9-]*(?:button|segment))(?![a-z0-9-])/g) {
            next if $seen{$c}++;
            next if $all =~ /\.\Q$c\E(?![a-z0-9-])[^{},]*:focus/;
            report("$f:$n", "the class .$c has no :focus rule (key focus has to show)");
        }
    }
    close $h;
}

for my $f (@rs) {
    open my $h, '<', $f or die "$f: $!";
    my $n = 0;
    while (<$h>) {
        $n++;
        report("$f:$n", "dim-label is deprecated since libadwaita 1.7: use dimmed") if /dim-label/;
    }
    close $h;
}
exit $fail;
PERL
