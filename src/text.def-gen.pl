#!/usr/bin/env perl
use strict;
use warnings;
use LWP::Simple;
use Cwd 'chdir';
use File::Basename;
use File::Slurp 'read_file';
use Getopt::Long;

my $UNICODE_VERSION = '7.0.0';
my $program = $0;

sub displayCLIHelp {
  print STDERR "Usage: $program --help\n";
  print STDERR "Usage: $program [options]\n";
  print STDERR "Options:\n";
  print STDERR "  --whitespace  Generate whitespace\n";
  print STDERR "  --ctrl        Generate control characters\n";
  print STDERR "  --linebreak   Generate linebreaks\n";
  print STDERR "  --casefold    Generate case folding\n";
  exit(1);
}

my $opt_all = 0;
my $opt_whitespace = 0;
my $opt_ctrl = 0;
my $opt_invalid = 0;
my $opt_linebreak = 0;
my $opt_casefold = 0;
my $opt_help = 0;
my $opt_digit = 0;
my $opt_bmpmap = 0;
GetOptions( 
  "whitespace"  => \$opt_whitespace,
  "ctrl"        => \$opt_ctrl,
  "invalid"     => \$opt_invalid,
  "linebreak"   => \$opt_linebreak,
  "casefold"    => \$opt_casefold,
  "digit"       => \$opt_digit,
  "bmpmap"      => \$opt_bmpmap,
  "help"        => \$opt_help
) or displayCLIHelp();

if ($opt_help) {
  displayCLIHelp();
}

if (!$opt_whitespace && !$opt_ctrl && !$opt_invalid && !$opt_linebreak && !$opt_casefold &&
    !$opt_digit && !$opt_bmpmap) {
  $opt_all = 1;
}

my $s;

print "// Generated by ".basename(__FILE__)."\n";
print "#define RX_TEXT_UNICODE_VERSION_STRING \"${UNICODE_VERSION}\"\n";
if ($UNICODE_VERSION =~ m/^(\d+)\.(\d+)\.(\d+)$/) {
  print "#define RX_TEXT_UNICODE_VERSION_MAJOR $1\n";
  print "#define RX_TEXT_UNICODE_VERSION_MINOR $2\n";
  print "#define RX_TEXT_UNICODE_VERSION_BUILD $3\n";
} else {
  die("Failed to parse \$UNICODE_VERSION ('$UNICODE_VERSION')");
}

sub fmtcp {
  return sprintf("%04X", shift);
}

sub readfileOrHTTPGET {
  my ($filename, $url) = @_;
  # filename should be relative the source root
  my $s;
  unless ($s = read_file(dirname(__FILE__).'/../'.$filename, err_mode => 'quiet')) {
    $s = LWP::Simple::get($url) or die;
  }
  return $s;
}

sub loadUnicodeDataFile {
  my ($filename) = @_;
  return readfileOrHTTPGET(
    "_etc/${filename}",
    "http://www.unicode.org/Public/${UNICODE_VERSION}/ucd/${filename}"
  );
}

# ===============================================================================================

my @BMPMap = ();
my $BMPMapMaxSize = 0x2FA1E;
my $BMPEndCP = 0;
my $BMPStartCP = $BMPMapMaxSize-1;

sub BMPMapAdd {
  my ($cp, $category, $bidirectionalCategory, $name) = @_;
  if ($cp < $BMPMapMaxSize) {
    if ($cp < $BMPStartCP) {
      $BMPStartCP = $cp;
    }
    if ($cp > $BMPEndCP) {
      $BMPEndCP = $cp;
    }
    my @pair = ($cp, $category, $bidirectionalCategory, $name);
    push(@BMPMap, \@pair);
  }
}

# ===============================================================================================

my @whitespaceCodepoints = ();
my @controlCodepoints = ();
my @invalidCodepointRanges = ();
# my @invalidCodepoints = ();
my $lastValidCodepoint = -1;

if ($opt_all || $opt_whitespace || $opt_ctrl || $opt_invalid || $opt_bmpmap) {

$s = loadUnicodeDataFile('UnicodeData.txt');

# See ftp://ftp.unicode.org/Public/3.0-Update/UnicodeData-3.0.0.html
# See   #General%20Category  for a list of categories (field 2)
#
#                 2F47;KANGXI RADICAL SUN;So;0;ON;<compat> 65E5;;;;N;;;;;
# 
#  Example line: "0004;<control>;Cc;0;BN; ; ; ; ;N;END OF TRANSMISSION;  ;  ;  ; ..."
#  Field:            0;        1; 2;3; 4;5;6;7;8;9;                 10;11;12;13; ...
#

my $prevCP = -1;

sub addCodepointRange {
  my ($ranges, $endCP, $startCP) = @_;
  if ($startCP == $endCP) { # single
    push($ranges, 'CP(0x'.fmtcp($startCP).')');
  } else {
    push($ranges, 'CR(0x'.fmtcp($startCP).', 0x'.fmtcp($endCP).')');
  }
}

my $queuedRangeStart = -1;

for (split /^/, $s) {
  my @entry = split(/;/, $_);

  my $codepoint = $entry[0];
  my $name = $entry[1];
  my $category = $entry[2];
  my $bidirectionalCategory = $entry[4];
  my $legacy_name = $entry[10];

  my $cp = hex($codepoint);

  # Named ranges
  #   3400;<CJK Ideograph Extension A, First>;Lo;0;L;;;;;N;;;;;
  #   4DB5;<CJK Ideograph Extension A, Last>;Lo;0;L;;;;;N;;;;;
  if ($name =~ m/^<(.+), ([^,]+)>$/) {
    if ($2 eq 'First') {
      $name = $1;
      if ($queuedRangeStart != -1) { die; }
      $queuedRangeStart = $cp;
    } elsif ($2 eq 'Last') {
      if ($queuedRangeStart == -1) { die; }
      $name = $1;
      # print "Range: $1  ".fmtcp($queuedRangeStart)." ... ".fmtcp($cp)."\n";
      for (my $c = $queuedRangeStart+1; $c != $cp; $c++) {
        if ($c < $BMPMapMaxSize) {
          BMPMapAdd($c, $category, $bidirectionalCategory, $name);
        }
        $prevCP = $c;
      }
      $queuedRangeStart = -1;
    }
  }


  if ($queuedRangeStart == -1 && $cp > $prevCP+1) {
    addCodepointRange(\@invalidCodepointRanges, $cp-1, $prevCP+1);
  }

  $prevCP = $cp;

  if ($category eq 'Zs') {
    push(@whitespaceCodepoints, "0x$codepoint, $name");
  } elsif ($category eq 'Cc') {
    if ($name eq '<control>') {
      $name = $legacy_name;
    }

    if ($codepoint ne '000A' && $codepoint ne '000D') {
      if ($name eq '') {
        push(@controlCodepoints, "0x$codepoint, ?");
      } else {
        push(@controlCodepoints, "0x$codepoint, $name");
      }
    }
  }

  if ($cp < $BMPMapMaxSize) {
    BMPMapAdd($cp, $category, $bidirectionalCategory, $name);
  }
}

$lastValidCodepoint = $prevCP;

# exit(0);

}
# ===============================================================================================

my @linebreakCodepoints = ();

if ($opt_all || $opt_linebreak) {

$s = loadUnicodeDataFile('LineBreak.txt');

# Example line:  "003C..003E;AL     # Sm     [3] LESS-THAN SIGN..GREATER-THAN SIGN"

for (split /^/, $s) {
  # print $_;
  my @entry = split(/;/, $_);
  if ($#entry > 0) {
    my $codepoints = $entry[0];
    if ($codepoints ne '000B..000C' && $entry[1] =~ m/^(\w+)\s+#\s+([^\s]+)\s+(?:\[\d+\])?\s*(.+)/) {
      my $type = $1;
      my $category = $2;
      my $name = $3;

      if (substr($name, 0, 8) eq '<control') {
        $name = $type;
      }

      if ($type eq 'LF' || $type eq 'CR' || $type eq 'BK') {
        if ($codepoints =~ m/^([^\.]+)\.{2}([^\.]+)$/) {
          # Codepoint range
          my $i = hex($1);
          my $end = hex($2)+1;
          # my @v = ();
          for (;$i != $end; $i++) {
            # push(@v, "0x".sprintf("%04X", $i));
            push(@linebreakCodepoints, "0x".sprintf("%04X", $i).", $name");
          }
          # push(@linebreakCases, 'case '.join(': case ', @v).": // $name");
          # push(@linebreakCases, "case 0x$1 ... 0x$2: // $name");
        } else {
          push(@linebreakCodepoints, "0x".$codepoints.", $name");
          # push(@linebreakCodepoints, "0x".fmtcp(hex($codepoints)).", $name");
          # push(@linebreakCases, 'case 0x'.fmtcp($codepoints).": // $name");
        }
      }
    # } else {
    #   print 'Did not match: ' . @entry . "\n";
    }
  }
}

}

# ===============================================================================================
# Find ranges

sub findCodepointRanges {
  my ($minCP, $codepoints) = @_;
  my $prevCP = -1;
  my $startCP = -1;
  my $cp = -1;
  my $lastFlushedCP = -1;

  my @ranges = ();
  my @sortedCodepoints = sort @$codepoints;

  foreach my $s (@sortedCodepoints) {
    $s =~ m/^0x([0-9A-Fa-f]+)/ or die('findCodepointRanges failed to find codepoint value');
    $cp = hex($1);

    if ($cp >= $minCP) {

      if ($startCP == -1) {
        # First codepoint
        $startCP = $cp;  # 000A
      } elsif ($cp > $prevCP+1) {
        # Theres a gap in the series -- flush range up to this point
        # print "X ".fmtcp($startCP).' ... '.fmtcp($prevCP)."\n";
        addCodepointRange(\@ranges, $prevCP, $startCP);
        $startCP = $cp;
      }

      $prevCP = $cp;  # 000A
    }
  }

  if ($startCP != -1) {
    # print "X ".fmtcp($startCP).' ... '.fmtcp($prevCP)."\n";
    addCodepointRange(\@ranges, $prevCP, $startCP);
  }

  return @ranges;
}

# ===============================================================================================

sub printEachDef {
  my ($macroName, $header, @codepoints) = @_;
  print("#define $macroName(CP) \\\n");
  if ($header ne '') {
    print "$header\n";
  }
  if ($#codepoints != -1) {
    print '  CP(' . join(") \\\n  CP(", @codepoints) . ")\n";
  }
  print("\n");
}

sub printRangesDef {
  my ($macroName, @codepoints) = @_;
  if ($#codepoints != -1) {
    print "#define $macroName(CP,CR) \\\n";
    print '  ' . join(" \\\n  ", @codepoints) . "\n";
    print "\n";
  }
}

my $BMPMapOffset = $BMPMap[0]->[0];
my $BMPMapSize = $BMPMap[$#BMPMap]->[0] - $BMPMap[0]->[0];
my $BMPMapLimitCP = $BMPMapSize + $BMPMapOffset;


if ($opt_all || $opt_whitespace) {
  printEachDef(  'RX_TEXT_WHITESPACE_CHARS', '', @whitespaceCodepoints);
  printRangesDef('RX_TEXT_WHITESPACE_RANGES', findCodepointRanges(0, \@whitespaceCodepoints));
  printRangesDef('RX_TEXT_WHITESPACE_MAP_ADDITION_RANGES',
    findCodepointRanges($BMPMapLimitCP, \@whitespaceCodepoints));
}

if ($opt_all || $opt_linebreak) {
  printEachDef(  'RX_TEXT_LINEBREAK_CHARS', '', @linebreakCodepoints);
  printRangesDef('RX_TEXT_LINEBREAK_RANGES', findCodepointRanges(0, \@linebreakCodepoints));
  printRangesDef('RX_TEXT_LINEBREAK_MAP_ADDITION_RANGES',
    findCodepointRanges($BMPMapLimitCP, \@linebreakCodepoints));
}

if ($opt_all || $opt_ctrl) {
  printEachDef(  'RX_TEXT_CTRL_CHARS', '', @controlCodepoints);
  printRangesDef('RX_TEXT_CTRL_RANGES', findCodepointRanges(0, \@controlCodepoints));
  printRangesDef('RX_TEXT_CTRL_MAP_ADDITION_RANGES',
    findCodepointRanges($BMPMapLimitCP, \@controlCodepoints));
}

if ($opt_all || $opt_invalid) {

  my @additionalInvalidCodepointRanges = ();
  foreach my $s (@invalidCodepointRanges) {
    $s =~ m/0x([0-9A-Fa-f]+)\)/ or die('findCodepointRanges2 failed to find codepoint value');
    my $cp = hex($1);
    if ($cp >= $BMPMapLimitCP) {
      push(@additionalInvalidCodepointRanges, $s);
    }
  }

  printRangesDef('RX_TEXT_INVALID_RANGES', @invalidCodepointRanges);
  printRangesDef('RX_TEXT_INVALID_MAP_ADDITION_RANGES', @additionalInvalidCodepointRanges);

  print "#define RX_TEXT_LAST_VALID_CHAR 0x".fmtcp($lastValidCodepoint)."\n\n";
}

if ($opt_all || $opt_digit) {

printEachDef('RX_TEXT_OCTDIGIT_CHARS', '', (
  '0x0030, DIGIT ZERO',
  '0x0031, DIGIT ONE',
  '0x0032, DIGIT TWO',
  '0x0033, DIGIT THREE',
  '0x0034, DIGIT FOUR',
  '0x0035, DIGIT FIVE',
  '0x0036, DIGIT SIX',
  '0x0037, DIGIT SEVEN')
);

printEachDef('RX_TEXT_DECDIGIT_CHARS',
  "  RX_TEXT_OCTDIGIT_CHARS(CP) \\", (
  '0x0038, DIGIT EIGHT',
  '0x0039, DIGIT NINE')
);

printEachDef('RX_TEXT_HEXADIGIT_UCASE_CHARS', '', (
  '0x0041,LATIN CAPITAL LETTER A',
  '0x0042,LATIN CAPITAL LETTER B',
  '0x0043,LATIN CAPITAL LETTER C',
  '0x0044,LATIN CAPITAL LETTER D',
  '0x0045,LATIN CAPITAL LETTER E',
  '0x0046,LATIN CAPITAL LETTER F')
);

printEachDef('RX_TEXT_HEXADIGIT_LCASE_CHARS', '', (
  '0x0061, LATIN SMALL LETTER A',
  '0x0062, LATIN SMALL LETTER B',
  '0x0063, LATIN SMALL LETTER C',
  '0x0064, LATIN SMALL LETTER D',
  '0x0065, LATIN SMALL LETTER E',
  '0x0066, LATIN SMALL LETTER F')
);

printEachDef('RX_TEXT_HEXDIGIT_UCASE_CHARS',
  "  RX_TEXT_DECDIGIT_CHARS(CP) \\\n".
  "  RX_TEXT_HEXADIGIT_UCASE_CHARS(CP)", ()
);

printEachDef('RX_TEXT_HEXDIGIT_LCASE_CHARS',
  "  RX_TEXT_DECDIGIT_CHARS(CP) \\\n".
  "  RX_TEXT_HEXADIGIT_LCASE_CHARS(CP)", ()
);

printEachDef('RX_TEXT_HEXDIGIT_CHARS',
  "  RX_TEXT_DECDIGIT_CHARS(CP) \\\n".
  "  RX_TEXT_HEXADIGIT_UCASE_CHARS(CP) \\\n".
  "  RX_TEXT_HEXADIGIT_LCASE_CHARS(CP)", ()
);

}


# ===============================================================================================

if ($opt_all || $opt_casefold) {

$s = loadUnicodeDataFile('CaseFolding.txt');

# Remove whole-line comments and empty lines
$s =~ s/^#.*\n//mg;
$s =~ s/^[\s\t ]*\n//mg;

# Remove full folds (we are performing simple folds aka point-to-point folds)
# Mappings that cause strings to grow in length. Multiple characters are separated by spaces.
$s =~ s/^.+ F; .+\n//mg;

# Remove special-case Turkic uppercase I and dotted uppercase I folding not used in other languages.
$s =~ s/^.+ T; .+\n//mg;

# Common and simple folds
my $caseFoldCodepointPairs = $s;
# my $caseFoldCases = $s;
# my $caseFoldConstExpr = $s;
$caseFoldCodepointPairs =~ s/^(.+); [CS]; (.+); # (.+)\n/  CP(0x$1, 0x$2, $3) \\\n/gm;
# $caseFoldCases          =~ s/^(.+); [CS]; (.+); # (.+)\n/    case 0x$1: return 0x$2; \/\/ $3\n/gm;
# $caseFoldConstExpr      =~ s/^(.+); [CS]; (.+); # (.+)\n/    c  == 0x$1 ? 0x$2 : \/\/ $3\n/gm;

print("#define RX_TEXT_CASE_FOLDS(CP) \\\n");
print($caseFoldCodepointPairs);
print("\n");

# print("UChar caseFold(UChar c) {\n");
# print("  switch (c) {\n");
# print($caseFoldCases);
# print("    default: return c; // Not folded\n");
# print("  }\n");
# print("}\n");

# Constexpr version:
# print("\n");
# print("// Generated by ".basename(__FILE__)."\n");
# print("constexpr UChar toLowerCX(UChar c) {\n");
# print("  return \n");
# print($caseFoldConstExpr);
# print("    c; // Not folded\n");
# print("}\n");

}

# ===============================================================================================

if ($opt_all || $opt_bmpmap) {

# print "BMPStartCP: ".fmtcp($BMPStartCP)."\n";
# print "BMPEndCP:   ".fmtcp($BMPEndCP)."\n";
# print "BMPMap:     \n";

my %knownNormativeCategories = (
  Lu => 'Letter, Uppercase',
  Ll => 'Letter, Lowercase',
  Lt => 'Letter, Titlecase',
  Mn => 'Mark, Non-Spacing',
  Mc => 'Mark, Spacing Combining',
  Me => 'Mark, Enclosing',
  Nd => 'Number, Decimal Digit',
  Nl => 'Number, Letter',
  No => 'Number, Other',
  Zs => 'Separator, Space',
  Zl => 'Separator, Line',
  Zp => 'Separator, Paragraph',
  Cc => 'Other, Control',
  Cf => 'Other, Format',
  Cs => 'Other, Surrogate',
  Co => 'Other, Private Use',
  Cn => 'Other, Not Assigned',
);

my %knownInformativeCategories = (
  Lm => 'Letter, Modifier',
  Lo => 'Letter, Other',
  Pc => 'Punctuation, Connector',
  Pd => 'Punctuation, Dash',
  Ps => 'Punctuation, Open',
  Pe => 'Punctuation, Close',
  Pi => 'Punctuation, Initial quote (may behave like Ps or Pe depending on usage)',
  Pf => 'Punctuation, Final quote (may behave like Ps or Pe depending on usage)',
  Po => 'Punctuation, Other',
  Sm => 'Symbol, Math',
  Sc => 'Symbol, Currency',
  Sk => 'Symbol, Modifier',
  So => 'Symbol, Other',
);

my %knownBidirectionalCategories = (
  # See http://www.unicode.org/reports/tr9/#Bidirectional_Character_Types

  # Strong
  L   => 'Left-to-Right',
  R   => 'Right-to-Left',
  AL  => 'Right-to-Left Arabic',

  # Weak
  EN  => 'European Number',
  ES  => 'European Number Separator',
  ET  => 'European Number Terminator',
  AN  => 'Arabic Number',
  CS  => 'Common Number Separator',
  NSM => 'Non-Spacing Mark',
  BN  => 'Boundary Neutral',

  # Neutral
  B   => 'Paragraph Separator',
  S   => 'Segment Separator',
  WS  => 'Whitespace',
  ON  => 'Other Neutrals',

  # Explicit Formatting
  LRE => 'Left-to-Right Embedding',
  LRO => 'Left-to-Right Override',
  RLE => 'Right-to-Left Embedding',
  RLO => 'Right-to-Left Override',
  PDF => 'Pop Directional Format',
  LRI => 'Left-to-Right Isolate',
  RLI => 'Right-to-Left Isolate',
  FSI => 'First Strong Isolate',
  PDI => 'Pop Directional Isolate',
);

# sort from lowest codepoint to highest codepoint
@BMPMap = sort { $a->[0] > $b->[0] } @BMPMap;
my $BMPMapHash = {}; # by codepoint

foreach my $pair (@BMPMap) {
  $BMPMapHash->{@$pair[0]} = $pair;
}

my $catHash = {};
my $bindirHash = {};

# my $BMPMapOffset = $BMPMap[0]->[0];
# my $BMPMapSize = $BMPMap[$#BMPMap]->[0] - $BMPMap[0]->[0];
# print "#define RX_TEXT_CHAR_MAP_OFFSET ".$BMPMapOffset."\n";
# print "#define RX_TEXT_CHAR_MAP_SIZE   ".$BMPMapSize."\n";
# print "#define RX_TEXT_CHAR_MAP(CP) \\\n";

# for (my $i=0; $i != $BMPMapSize; $i++) {
#   if (!defined $BMPMapHash->{$i}) {
#     print "Undefined codepoint $i\n";
#   }
#   # push(@invalidCodepoints, '0x'.fmtcp($i));
# }

# exit(0);

my @BMPMapEntries = ();

for (my $i=0; $i != $BMPMapSize; $i++) {
  my $cphex = $i;
  my $cpDescr = '';

  if ($BMPMapOffset == 0) {
    $cphex = '0x'.fmtcp($i);
  } else {
    $cpDescr = "(U+".fmtcp($i).") ";
    $cphex = sprintf("0x%04x", $i - $BMPMapOffset);
  }

  if (!defined $BMPMapHash->{$i}) {
    push(@BMPMapEntries, "$cphex, UNASSIGNED, UNDEFINED, \"\"");

  } else {
    my $pair = $BMPMapHash->{$i};

    my $flag;
    my @flags = ();
    my $description = '';
    my $catTag = '';

    if (defined $knownNormativeCategories{$pair->[1]}) {
      $description = $knownNormativeCategories{$pair->[1]};
      $catTag = 'NORM_';
    } elsif (defined $knownInformativeCategories{$pair->[1]}) {
      $description = $knownInformativeCategories{$pair->[1]};
      $catTag = 'INFO_';
    }

    $flag = $catTag.$pair->[1];
    push(@flags, $flag);
    $catHash->{$flag} = $description;

    $description = '';
    if (defined $knownBidirectionalCategories{$pair->[2]}) {
      $description = $knownBidirectionalCategories{$pair->[2]};
    }
    $flag = $pair->[2];
    push(@flags, $flag);
    $bindirHash->{$flag} = $description;

    push(@BMPMapEntries, "$cphex, ".join(', ', @flags).", \"".$pair->[3]."$cpDescr\"");

    # print "  ".$value.", ".$category.", ".@$pair[$#{$pair}]."\n";
    # print "  CAT_".@$pair->[1]."( ".$value.", ".join(', ', @$pair[2..$#{$pair}])." ) \\\n";
    # print "  BIDIRCAT_".@$pair->[2]."( ".$value.", ".@$pair->[1].", ".join(', ', @$pair[3..$#{$pair}])." ) \\\n";
  }
}
print "\n";


sub printFlags {
  my ($defNamePrefix, $catHash) = @_;
  my $value = 0;
  my @sortedCatFlags = ();
  while ( my ($name, $description) = each(%$catHash) ) {
    push(@sortedCatFlags, sprintf("%-".(28-length($defNamePrefix))."s", $name)." /* $description */");
  }
  foreach my $name (sort @sortedCatFlags) {
    print "#define ${defNamePrefix}$name ".(++$value)."\n";
  }
  print "#define ${defNamePrefix}MAX     ".$value."\n";
}

print "// Character categories\n";
print "// See http://www.unicode.org/notes/tn36/ and http://www.unicode.org/notes/tn36/Categories.txt\n";
print "#define RX_TEXT_CHAR_CAT_UNASSIGNED  /* (Cn) Other, Not Assigned */ 0\n";
printFlags('RX_TEXT_CHAR_CAT_', $catHash);
print "\n";

print "// Bidirectional character types\n";
print "// See http://www.unicode.org/reports/tr9/#Bidirectional_Character_Types\n";
print "#define RX_TEXT_CHAR_BIDIR_UNDEFINED 0\n";
printFlags('RX_TEXT_CHAR_BIDIR_', $bindirHash);
print "\n";

# 'RX_TEXT_CHAR_BIDIR_'.

# my $nextCatFlagValue = 0;
# my @sortedCatFlags = ();
# while ( my ($name, $description) = each(%$catHash) ) {
#   push(@sortedCatFlags, sprintf("%-25s", $name)." /* $description */");
# }
# foreach my $name (sort @sortedCatFlags) {
#   print "#define $name ".(++$nextCatFlagValue)."\n";
# }
# print "#define RX_TEXT_CHAR_CAT_MAX     ".$nextCatFlagValue."\n";

print "\n";
print "// Character map (U+".fmtcp($BMPMapOffset)." ... U+".fmtcp(($BMPMapSize+$BMPMapOffset)-1).")\n";
print "#define RX_TEXT_CHAR_MAP_OFFSET ".$BMPMapOffset."\n";
print "#define RX_TEXT_CHAR_MAP_SIZE   ".$BMPMapSize."\n";
print "#define RX_TEXT_CHAR_MAP(CP) \\\n";
print '  CP( ' . join(") \\\n  CP( ", @BMPMapEntries).")\n";

} # if ($opt_all || $opt_bmpmap)



