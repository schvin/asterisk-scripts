#!/usr/bin/perl
#
# Allows resending of voice mails from Asterisk via email, in the event
# the original emails were lost or not delivered correctly.
#
# Assumes users are configured locally in text files and not in a
# database/etc.
#
# XXX have script check local system and/or asterisk time zone...
#
# XXX uses default emailsubject and emailbody from voicemail.conf, plus
# a disclaimer about the delay/resend.  May need adjustment for custom
# email message configurations...
#
# XXX minor date formatting adjustments in the body should be cleaned up.
#
###

use warnings;
use strict;
use MIME::Lite;
use DateTime;

my $base;
my $config;
my $d;
my $user;
my $vid;

$config = '/etc/asterisk';
$base   = '/var/spool/asterisk/voicemail/default';

if($#ARGV != 1) {
  usage();
}
$user = $ARGV[0];
$vid  = $ARGV[1];
if(!($user =~ /^\d+$/ && $vid =~ /^\d{1,4}$/)) {
  usage();
}

# pad vid, as it is 4 digits with leading zeros
$vid = sprintf("%04d", $vid);

$d = getvmail($base, $user, $vid);
smail($config, $base, $d);

sub getvmail {

  my $base;
  my %d;
  my $dt;
  my $file;
  my $i;
  my $line;
  my $seconds;
  my $user;
  my $vid;

  local *FD;

  $base = shift;
  $user = shift;
  $vid  = shift;

  # set callerid to blank, sometimes it is not there.
  $d{callerid} = "";

  if(-d "$base/$user/INBOX") {
    $file = "$base/$user/INBOX/msg$vid.txt";
    if(-e $file) {
      print "Found voice mail $vid for user $user...\n";
      open(FD, "< $file") || die("$!: $file not readable\n");
      while($line = <FD>) {
        chomp $line;
        if($line =~ /^origmailbox=(\d+)/) {
          $d{mailbox} = $1;
        } elsif($line =~ /^callerid=\"([^\"]+)\"/) {
          $d{callerid} = $1;
        } elsif($line =~ /^origtime=(\d+)/) {
          $dt = DateTime->from_epoch( epoch => $1 );
          $dt->set_time_zone('-0400'); # XXX
          $d{date} = $dt->day_name . ", " . $dt->month_name . " "
              . $dt->day . " " . $dt->year . " at " . $dt->hms;
          # Tuesday, September 13, 2011 at 05:29:25 PM
          # XXX using 24-hr clock rather than am/pm
        } elsif($line =~ /^duration=(\d+)/) {
          $seconds = $1;
          if($seconds > 59) {
            $d{duration} = int($seconds / 60) . ":" .
                sprintf("%02d", $seconds % 60);
          } else {
            $d{duration} = "0:" . sprintf("%02d", $seconds);
          }
        }
      }
      $d{number} = $vid;
      $d{number} =~ s/^0+//;
      $d{number}++;
      close(FD);
    } else {
      print "Voicemail $vid for user $user does not exist.\n";
      exit(1);
    }
  } else {
    print "User $user does not exist.\n";
    exit(1);
  }

  return(\%d);

}

sub usage {

  print "This script re-sends a voice mail to a specified user.\n\n",
        "Please specify the numerical user and the voice mail number:\n\n",
        "\t./resend-voicemail.pl 7000 105\n";
  exit(1);

}

sub smail {

  my $base;
  my $config;
  my $d;
  my $email;
  my $msg;
  my $name;
  my $sender;

  $config = shift;
  $base   = shift;
  $d      = shift;

  $sender         = getsender($config);
  ($name, $email) = getrecipient($config, $user);

  $msg = MIME::Lite->new(
    From    => $sender,
    To      => $email,
    Subject => "[PBX]: New message $d->{number} in mailbox $d->{mailbox}",
    Type    => 'multipart/mixed'
  );

  $msg->attach(Type     =>'text/plain',
               Data     => "This email message was delayed due to a system issue.\n\nDear $name:\n\n\tJust wanted to let you know you were just left a $d->{duration} long message (number $d->{number})\nin mailbox $d->{mailbox} from $d->{callerid}, on $d->{date}, so you might\nwant to check it when you get a chance.  Thanks!\n\n\t\t\t\t--Asterisk\n"
  );

  $msg->attach(Type => 'audio/x-wav',
               Id   => 'msg$vid.WAV',
               Path => "$base/$user/INBOX/msg$vid.WAV"
  );

  MIME::Lite->send('smtp', '127.0.0.1', Debug=>0);

  $msg->send();

  print "Message sent...\n";

  return();

}

sub getrecipient {

  my $config;
  my $email;
  my $line;
  my $name;
  my $pos;
  my $file;
  my $user;

  local *FD;

  $config = shift;
  $user   = shift;
  $file   = "$config/users.conf";

  $pos = 0;
  if(-e $file) {
    open(FD, "< $file") || die("$!: can not read $file\n");
    while($line = <FD>) {
      if('0' == $pos) {
        if($line =~ /^\[$user\]/) {
          $pos = 1;
        }
      } else {
        if($line =~ /^\[\d+\]/) {
          $pos = 0;
        } elsif($line =~ /^fullname\s*=\s*(.*)/) {
          $name = $1;
        } elsif($line =~ /^email\s*=\s(.*)/) {
          $email = $1;
        }
      }
    }
    close(FD);

  } else {
    print "Could not find $file to read in user data.\n";
    exit(1);
  }

  # XXX sloppy match, depends on environment...
  if($name && $email && $name =~ /\w/ && $email =~ /\w/) {
    return($name, $email);
  } else {
    print "Could not find adequate email and fullname settings for user.\n";
    exit(1);
  }

}

sub getsender {

  my $config;
  my $file;
  my $line;
  my $sender;

  local *FD;

  $config = shift;
  $file   = "$config/voicemail.conf";

  # set default in case one is not found
  $sender = 'asterisk';

  if(-e $file) {
    open(FD, "< $file") || die("$!: can not read $file\n");
    while($line = <FD>) {
      chomp $line;
      if($line =~ /^serveremail\s*=\s*([^\s]+)/) {
        $sender = $1;
      }
    }
  }

  return($sender);

}
