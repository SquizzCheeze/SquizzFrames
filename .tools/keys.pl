# Print every table key (identifier = ...) in the given Lua files, ignoring
# comments and strings. Used by check-keys.sh.
my %k;
for my $f (@ARGV) {
    open my $h, '<', $f or die "$f: $!";
    while (<$h>) {
        s/--.*$//;
        s/"(?:[^"\\]|\\.)*"//g;
        while (/(?:^|[{,\s])([A-Za-z_][A-Za-z0-9_]*)\s*=(?!=)/g) { $k{$1} = 1 }
    }
}
print "$_\n" for sort keys %k;
