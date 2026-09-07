#!/usr/bin/env perl
use strict;
use warnings;

@ARGV == 2 or die "usage: pack_icns.pl ICONSET OUTPUT.icns\n";
my ($iconset, $output) = @ARGV;

my @entries = (
    ["icp4", "icon_16x16.png"],
    ["icp5", "icon_32x32.png"],
    ["icp6", "icon_32x32\@2x.png"],
    ["ic07", "icon_128x128.png"],
    ["ic08", "icon_256x256.png"],
    ["ic09", "icon_512x512.png"],
    ["ic10", "icon_512x512\@2x.png"],
    ["ic11", "icon_16x16\@2x.png"],
    ["ic12", "icon_32x32\@2x.png"],
    ["ic13", "icon_128x128\@2x.png"],
    ["ic14", "icon_256x256\@2x.png"],
);

my $chunks = "";
for my $entry (@entries) {
    my ($type, $file) = @$entry;
    my $path = "$iconset/$file";
    open my $image, "<:raw", $path or die "error: cannot read $path: $!\n";
    local $/;
    my $data = <$image>;
    close $image;
    $chunks .= $type . pack("N", length($data) + 8) . $data;
}

my $temporary = "$output.tmp.$$";
open my $destination, ">:raw", $temporary
    or die "error: cannot write $temporary: $!\n";
print {$destination} "icns", pack("N", length($chunks) + 8), $chunks;
close $destination;
rename $temporary, $output or die "error: cannot replace $output: $!\n";
