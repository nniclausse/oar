#!/usr/bin/perl -w
# vim: set foldmethod=marker:syntax: #
#
# This is the main cgi script for the OAR REST API
# This script is part of the OAR project.
#
# Please, make a good usage of folding markers: {{{ and }}}
# into comments. Under vim, use "za" to fold and "zo" to
# unfold (or just go inside the title to automatically unfold)
# You have to ":set modeline" into vim for the above modeline
# to be interpreted by vim or just type the :set command given
# by this modeline.
#
#    Copyright (C) 2009-2010  <Bruno Bzeznik> Bruno.Bzeznik@imag.fr
#
#    This program is free software; you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation; either version 2 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program; if not, write to the Free Software
#    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
# 

use strict;
use DBI();
use OAR::API;
use OAR::Conf qw(init_conf dump_conf get_conf_list get_conf is_conf set_value);
use OAR::IO;
use OAR::Stat;
use OAR::Nodes;
use OAR::Tools;
use OAR::Version;
use POSIX;
use JSON;
use IO::Handle;
use File::Temp qw/ tempfile  /;
use File::Basename;
use CGI::Fast qw/ standard /;


#use Data::Dumper;

my $VERSION="1.0.1alpha1";

##############################################################################
# CONFIGURATION AND INITIALIZATION STUFF
##############################################################################

# Load config
my $oardir;
if (defined($ENV{OARDIR})){
    $oardir = $ENV{OARDIR}."/";
}else{
    die("ERROR: OARDIR env variable must be defined.\n");
}
if (defined($ENV{OARCONFFILE})){
  init_conf($ENV{OARCONFFILE});
}else{
  init_conf("/etc/oar/oar.conf");
}

# Oar commands
my $OARSUB_CMD  = "oarsub";
my $OARDEL_CMD  = "oardel";
my $OARHOLD_CMD  = "oarhold";
my $OARRESUME_CMD  = "oarresume";
my $OARADMIN_CMD = "oaradmin";
my $OARNODES_CMD = "oarnodes";
my $OARDODO_CMD = "$ENV{OARDIR}/oardodo/oardodo";

# OAR server
my $remote_host = get_conf("SERVER_HOSTNAME");
my $remote_port = get_conf("SERVER_PORT");
my $stageout_dir = get_conf("STAGEOUT_DIR");
my $stagein_dir = get_conf("STAGEIN_DIR");
my $allow_create_node = get_conf("DESKTOP_COMPUTING_ALLOW_CREATE_NODE");
my $expiry = get_conf("DESKTOP_COMPUTING_EXPIRY");

# Enable this if you are ok with a simple pidentd "authentication"
# Not very secure, but useful for testing (no need for login/password)
# or in the case you fully trust the client hosts (with an apropriate
# ip-based access control into apache for example)
my $TRUST_IDENT = 1;
if (is_conf("API_TRUST_IDENT")){ $TRUST_IDENT = get_conf("API_TRUST_IDENT"); }

# Default data structure variant
my $STRUCTURE="simple";
if (is_conf("API_DEFAULT_DATA_STRUCTURE")){ $STRUCTURE = get_conf("API_DEFAULT_DATA_STRUCTURE"); }
my $DEFAULT_STRUCTURE=$STRUCTURE;

# Get the default maximum number of items
my $MAX_ITEMS=500;
if (is_conf("API_DEFAULT_MAX_ITEMS_NUMBER")){ $MAX_ITEMS = get_conf("API_DEFAULT_MAX_ITEMS_NUMBER"); }

# Relative/absolute uris config variable
$OAR::API::ABSOLUTE_URIS=1;
if (is_conf("API_ABSOLUTE_URIS")){ $OAR::API::ABSOLUTE_URIS=get_conf("API_ABSOLUTE_URIS"); }

# TMP directory
my $TMPDIR="/tmp";
if (defined($ENV{TMPDIR})) {
  $TMPDIR=$ENV{TMPDIR};
}

# Load the html header file
my $file;
if (is_conf("API_HTML_HEADER")){ $file=get_conf("API_HTML_HEADER"); }
else { $file="/etc/oar/api_html_header.pl"; }
open(FILE,$file);
my(@html_header_lines) = <FILE>;
close(FILE);


##############################################################################
# FastCGI loop starting
##############################################################################
my $q;
FCGI: while ($q = new CGI::Fast) {

# Sets the cgi handler of the OAR::API (global variable)
$OAR::API::q=$q;

# Activate debug mode when the script name contains "debug" or when a
# debug parameter is found.
my $DEBUG_MODE=0;
if ( $q->url(-relative=>1) =~ /.*debug.*/ ) { $DEBUG_MODE = 1; };
if ( defined( $q->param('debug') ) && $q->param('debug') eq "1" ) {
  $DEBUG_MODE = 1;
}
$OAR::API::DEBUG_MODE=$DEBUG_MODE;

# Check a possible extension
my $extension;
if ( $q->path_info =~ /^$/ ) { $extension = "html"; }
elsif ( $q->path_info =~ /.*\.(yaml|json|html|tgz|tar\.gz)$/ ) { $extension = $1; };
$extension=OAR::API::set_ext($q,$extension);
$OAR::API::extension=$extension;

# Base uri of the api
my $apiuri=OAR::API::get_api_uri_relative_base();
$apiuri =~ s/\/$//;
$OAR::API::apiuri=$apiuri;

# Header for html version
my $HTML_HEADER="";
eval join("\n",@html_header_lines);
$OAR::API::HTML_HEADER=$HTML_HEADER;

##############################################################################
# Authentication
##############################################################################

my $authenticated_user = "";

if ( defined( $ENV{AUTHENTICATE_UID} ) && $ENV{AUTHENTICATE_UID} ne "" ) {
  $authenticated_user = $ENV{AUTHENTICATE_UID};
}
else {
  if ( $TRUST_IDENT
    && defined( $q->http('X_REMOTE_IDENT') )
    && $q->http('X_REMOTE_IDENT') ne ""
    && $q->http('X_REMOTE_IDENT') ne "unknown" 
    && $q->http('X_REMOTE_IDENT') ne "(null)" )
  {
    $authenticated_user = $q->http('X_REMOTE_IDENT');
  }
}

##############################################################################
# Data structure variants
##############################################################################
$STRUCTURE=$DEFAULT_STRUCTURE;
if (defined $q->param('structure')) {
  $STRUCTURE=$q->param('structure');
}
if ($STRUCTURE ne "oar" && $STRUCTURE ne "simple") {
  OAR::API::ERROR 406, "Unknown $STRUCTURE format",
        "Unknown $STRUCTURE format for data structure";
  last FCGI;
}


##############################################################################
# URI management
##############################################################################

SWITCH: for ($q) {
  my $URI;

  ###########################################
  # API informations
  ###########################################
  #
  #{{{ GET /: Root links
  #
  $URI = qr{^\/*\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$1);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    my $root={    "oar_version" => OAR::Version::get_version(),
                  "api_version" => $VERSION,
                  "apilib_version" => OAR::API::get_version(),
                  "api_timestamp" => time(),
                  "api_timezone" => strftime("%Z", localtime()),
                  "links" => [ 
                      { 'rel' => 'self' , 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("./",$ext,0),$ext) 
                      },
                      { 'rel' => 'collection', 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("resources",$ext,0),$ext),
                        'title' => 'resources'
                      } ,
                      { 'rel' => 'collection', 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("resources/full",$ext,0),$ext),
                        'title' => 'full_resources'
                      } ,
                      { 'rel' => 'collection', 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("jobs",$ext,0),$ext),
                        'title' => 'jobs'
                      } ,
                      { 'rel' => 'collection', 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("jobs/details",$ext,0),$ext),
                        'title' => 'detailed_jobs'
                      } ,
                      { 'rel' => 'collection', 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("jobs/table",$ext,0),$ext),
                        'title' => 'jobs_table'
                      } ,
                      { 'rel' => 'collection', 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("config",$ext,0),$ext),
                        'title' => 'config'
                      } ,
                      { 'rel' => 'collection', 
                        'href' => OAR::API::htmlize_uri(OAR::API::make_uri("admission_rules",$ext,0),$ext),
                        'title' => 'admission_rules'
                      } 
                             ]
             };
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($root,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /version : Version informations
  #
  $URI = qr{^/version\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$1);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    my $version={ "oar_version" => OAR::Version::get_version(),
                  "apilib_version" => OAR::API::get_version(),
                  "api_timestamp" => time(),
                  "api_timezone" => strftime("%Z", localtime()),
                  "api_version" => $VERSION };
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($version,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /timezone: Timezone information
  #
  $URI = qr{^/timezone\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$1);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    my $version={ 
                  "api_timestamp" => time(),
                  "timezone" => strftime("%Z", localtime())
                };
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($version,$ext);
    last;
  };
  #}}}

  ###########################################
  # Jobs
  ###########################################
  #
  #{{{ GET /jobs[/details|table]?state=<state>,from=<from>,to=<to> : List of jobs
  #
  $URI = qr{^/jobs(/details|/table)*\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext=OAR::API::set_ext($q,$2);
    my $header ; my $type; 
    my $more_infos=$1;
    if (!defined($more_infos)) { 
      ($header,$type)=OAR::API::set_output_format($ext,"GET, POST");
    }else{
      ($header,$type)=OAR::API::set_output_format($ext);
    }

    # Get the id of the user as more details may be obtained for her jobs
    if ( $authenticated_user =~ /(\w+)/ ) {
      $authenticated_user = $1;
      $ENV{OARDO_USER} = $authenticated_user;
    }

    OAR::Stat::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                          );

    # default parameters for the parameters
    my $JOBS_URI_DEFAULT_PARAMS = "state=Finishing,Running,Resuming,Suspended,Launching,toLaunch,Waiting,toAckReservation,Hold";
    if (is_conf("API_JOBS_URI_DEFAULT_PARAMS")){ $JOBS_URI_DEFAULT_PARAMS = get_conf("API_JOBS_URI_DEFAULT_PARAMS"); }

    # query string parameters
    my $from = $q->param('from');
    my $to = $q->param('to');
    my $state = $q->param('state');
    my $user = $q->param('user');
    my $array = $q->param('array');

    if (!defined($q->param('from')) && !defined($q->param('to')) && !defined($q->param('state')) && !defined($q->param('array'))) {
        my $param = qr{.*from=(.*?)(&|$)};
        if ($JOBS_URI_DEFAULT_PARAMS =~ m/$param/) {
        	$from = $1;
        }
    	$param = qr{.*to=(.*?)(&|$)};
    	if ($JOBS_URI_DEFAULT_PARAMS =~ m/$param/) {
        	$to = $1;
        }
    	$param = qr{.*state=(.*?)(&|$)};
    	if ($JOBS_URI_DEFAULT_PARAMS =~ m/$param/) {
        	$state = $1;
        }
    }
    if (!defined($array)) { $array=""; };

    # GET max items from configuration parameter
    if (!defined($q->param('from')) && !defined($q->param('to')) && !defined($q->param('state')) && !defined($q->param('limit'))) {
    	# get limit from defaut url
        my $param = qr{.*limit=(.*?)(&|$)};
        
        if ($JOBS_URI_DEFAULT_PARAMS =~ m/$param/) {
        	$MAX_ITEMS = $1;
        }
    }
    # GET max items from uri parameter
    if (defined($q->param('limit'))) {
        $MAX_ITEMS = $q->param('limit');
    }
    # set offset / GET offset from uri parameter
    my $offset = 0;
    if (defined($q->param('offset'))) {
        $offset = $q->param('offset');
    }
    # requested user jobs
    my $jobs = OAR::Stat::get_jobs_for_user_query($user,$from,$to,$state,$MAX_ITEMS,$offset,$array);
    my $total_jobs = OAR::Stat::count_jobs_for_user_query($user,$from,$to,$state,$array);
    
    if ( !defined $jobs || keys %$jobs == 0 ) {
      $jobs = OAR::API::struct_empty($STRUCTURE);
    }
    else {
    	
    	$jobs = OAR::API::struct_job_list_hash_to_array($jobs);
      	OAR::API::add_joblist_uris($jobs,$ext);
      	
      	if (defined($more_infos)) {
        	if ($more_infos eq "/details") {
           	  # will be useful for cigri and behaves as a oarstat -D
                  # Warning: it's a kind of all in one query and may result in a lot of
                  # SQL queries. Maybe to optimize...
                  my $detailed_jobs;
                  foreach my $j (@$jobs) {
                    my $job_resources = OAR::Stat::get_job_resources($j);
                    $j = OAR::Stat::get_job_data($j,1);
                    my $resources = OAR::API::struct_job_resources($job_resources,$STRUCTURE);
                    my $nodes= OAR::API::struct_job_nodes($job_resources,$STRUCTURE);
                    OAR::API::add_resources_uris($resources,$ext,'');
                    $j->{'resources'}=$resources; 
                    OAR::API::add_nodes_uris($nodes,$ext,'');
                    $j->{'nodes'}=$nodes; 
                    $j = OAR::API::struct_job($j,$STRUCTURE);
                    OAR::API::add_job_uris($j,$ext);
                    push(@$detailed_jobs,$j);
                  }
                  $jobs = $detailed_jobs;

        	}
      	}
      	else {
          	$jobs = OAR::API::struct_job_list($jobs,$STRUCTURE);
      	}
    }
    OAR::Stat::close_db_connection();
    
    # add pagination informations
    $jobs = OAR::API::add_pagination($jobs,$total_jobs,$q->path_info,$q->query_string,$ext,$MAX_ITEMS,$offset,$STRUCTURE);
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($jobs,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /jobs/<id> : Details of a job
  #
  $URI = qr{^/jobs/(\d+)(\.yaml|\.json|\.html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $jobid = $1;
    my $ext=OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext,"GET, POST, DELETE");
    
    # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before looking at jobs" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_USER} = $authenticated_user;

    OAR::Stat::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $job = OAR::Stat::get_specific_jobs([$jobid]);
    if (@$job == 0 ) {
      OAR::API::ERROR( 404, "Job not found",
        "Job not found" );
      last;
    }
    $job=OAR::Stat::get_job_data(@$job[0],1);
    my $result = OAR::API::struct_job($job,$STRUCTURE);
    OAR::API::add_job_uris($result,$ext);
    OAR::Stat::close_db_connection; 
    print $header;
    if ($ext eq "html") { OAR::API::job_html_header($job); };
    print OAR::API::export($result,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /jobs/<id>/[resources|nodes] : Resources or nodes assigned or scheduled to a job
  #
  $URI = qr{^/jobs/(\d+)/(resources|nodes)(\.yaml|\.json|\.html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $jobid = $1;
    my $item = $2;
    my $ext=OAR::API::set_ext($q,$3);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    OAR::Stat::open_db_connection or OAR::API::ERROR(500,
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $job = OAR::Stat::get_specific_jobs([$jobid]);
    my $resources=OAR::Stat::get_job_resources(@$job[0]);
    if ($item eq "resources") {
      $resources = OAR::API::struct_job_resources($resources,$STRUCTURE);
      OAR::API::add_resources_uris($resources,$ext,''); 
    }else{
      $resources = OAR::API::struct_job_nodes($resources,$STRUCTURE);
      OAR::API::add_nodes_uris($resources,$ext,''); 
    }
    $resources = OAR::API::add_pagination($resources,@$resources,$q->path_info,undef,$ext,0,0,$STRUCTURE);
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($resources,$ext);
    last;
  };
  #}}}
  #
  #{{{ POST /jobs/[array/]<id>/checkpoints|deletions|holds|rholds|resumptions|resubmissions/new : Actions on a job (checkpoint, hold, resume,...)
  #
  $URI = qr{^/jobs/(array/|)(\d+)/(checkpoints|deletions|holds|rholds|resumptions|resubmissions)+/new(\.yaml|\.json|\.html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $array = $1;
    my $jobid = $2;
    my $action = $3;
    my $ext=OAR::API::set_ext($q,$4);
    (my $header, my $type)=OAR::API::set_output_format($ext,"GET, POST");
 
     # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before modifying jobs" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    if ($array eq "array/") { $array="--array"; }

    # Delete (alternative way to DELETE request, for html forms)
    my $cmd; my $status;
    if ($action eq "deletions" ) {
      $cmd    = "$OARDODO_CMD $OARDEL_CMD $array $jobid";
      $status = "Delete request registered"; 
    }
    # Checkpoint
    elsif ( $action eq "checkpoints" ) {
      $cmd    = "$OARDODO_CMD $OARDEL_CMD $array -c $jobid";
      $status = "Checkpoint request registered"; 
    }
    # Hold
    elsif ( $action eq "holds" ) {
      $cmd    = "$OARDODO_CMD $OARHOLD_CMD $array $jobid";
      $status = "Hold request registered";
    }
    # Hold a running job
    elsif ( $action eq "rholds" ) {
      $cmd    = "$OARDODO_CMD $OARHOLD_CMD $array -r $jobid";
      $status = "Hold request registered";
    }
    # Resume
    elsif ( $action eq "resumptions" ) {
      $cmd    = "$OARDODO_CMD $OARRESUME_CMD $array $jobid";
      $status = "Resume request registered";
    }
    # Resubmit
    elsif ( $action eq "resubmissions" ) {
      $cmd    = "$OARDODO_CMD $OARSUB_CMD $array --resubmit $jobid";
      $status = "Resubmit request registered";
    }
    # Impossible to get here!
    else {
      OAR::API::ERROR(400,"Bad query","Could not understand ". $action ." method"); 
      last;
    }

    my $cmdRes = OAR::API::send_cmd($cmd,"Oar");

    # Resubmit case (it is a oarsub and we have to catch the new job_id)
    if ($action eq "resubmissions" ) {
      if ( $? != 0 ) {
        my $err = $? >> 8;
        OAR::API::ERROR(
          500,
          "Oar server error",
          "Oarsub command exited with status $err: $cmdRes\nCmd:\n$cmd"
        );
      }
      elsif ( $cmdRes =~ m/.*JOB_ID\s*=\s*(\d+).*/m ) {
        print $q->header( -status => 201, -type => "$type" );
        print $HTML_HEADER if ($ext eq "html");
        print OAR::API::export( {
                        'id' => int($1),
                        'links' => [ { 'rel' => 'self' , 'href' => 
                          OAR::API::htmlize_uri(OAR::API::make_uri("jobs/$1",$ext,0),$ext) },
                                     { 'rel' => 'parent', 'href' => 
                          OAR::API::htmlize_uri(OAR::API::make_uri("jobs/$jobid",$ext,0),$ext) } ],
                        'status' => "submitted",
                        'cmd_output' => "$cmdRes",
                        'api_timestamp' => time()
                      } , $ext );
      }else {
        OAR::API::ERROR( 500, "Parse error",
          "Job submitted but the id could not be parsed.\nCmd:\n$cmd" );
      }

    # Other cases
    }else{
      print $q->header( -status => 202, -type => "$type" );
      print $HTML_HEADER if ($ext eq "html");
      print OAR::API::export( { 'id' => "$jobid",
                      'status' => "$status",
                      'cmd_output' => "$cmdRes",
                      'api_timestamp' => time(),
                      'links' => [ { 'rel' => 'self' , 'href' => 
                          OAR::API::htmlize_uri(OAR::API::make_uri("jobs/$jobid",$ext,0),$ext) } ]
                    } , $ext );
    }
    last;
  };
  #}}}
  #
  #{{{ POST /jobs/<id> : Update of a job (delete, checkpoint, ...)
  # Should not be used unless for delete from an http browser
  # (better to use the URI above)
  #
  $URI = qr{^/jobs/(\d+)(\.yaml|\.json|\.html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $jobid = $1;
    my $ext=OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext,"GET, POST");
 
     # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before modifying jobs" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    # Check and get the submitted data
    # From encoded data
    my $job;
    if ($q->param('POSTDATA')) {
      $job = OAR::API::check_job_update( $q->param('POSTDATA'), $q->content_type );
    }
    # From html form
    else {
      $job = OAR::API::check_job_update( $q->Vars, $q->content_type );
    }
    
    # Delete (alternative way to DELETE request, for html forms)
    my $cmd; my $status;
    if ( $job->{method} eq "delete" ) {
      $cmd    = "$OARDODO_CMD $OARDEL_CMD $jobid";
      $status = "Delete request registered"; 
    }
    # Checkpoint
    elsif ( $job->{method} eq "checkpoint" ) {
      $cmd    = "$OARDODO_CMD $OARDEL_CMD -c $jobid";
      $status = "Checkpoint request registered"; 
    }
    # Hold
    elsif ( $job->{method} eq "hold" ) {
      $cmd    = "$OARDODO_CMD $OARHOLD_CMD $jobid";
      $status = "Hold request registered";
    }
    # Resume
    elsif ( $job->{method} eq "resume" ) {
      $cmd    = "$OARDODO_CMD $OARRESUME_CMD $jobid";
      $status = "Resume request registered";
    }
    else {
      OAR::API::ERROR(400,"Bad query","Could not understand ". $job->{method} ." method"); 
      last;
    }

    my $cmdRes = OAR::API::send_cmd($cmd,"Oar");
    print $q->header( -status => 202, -type => "$type" );
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export( { 'id' => "$jobid",
                    'status' => "$status",
                    'cmd_output' => "$cmdRes",
                    'api_timestamp' => time(),
                    'links' => [ { 'rel' => 'self' , 'href' => 
                          OAR::API::htmlize_uri(OAR::API::make_uri("jobs/$jobid",$ext,0),$ext) } ]
                  } , $ext );
    last;
  };
  #}}}
  #
  #{{{ POST /jobs/<id>/signals/<signal> : Signal sending
  #
  $URI = qr{^/jobs/(\d+)/signals/(\d+)(\.yaml|\.json|\.html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $jobid = $1;
    my $signal = $2;
    my $ext=OAR::API::set_ext($q,$3);
    (my $header, my $type)=OAR::API::set_output_format($ext,"GET, POST");
 
     # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before modifying jobs" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    my $cmd    = "$OARDODO_CMD $OARDEL_CMD -s $signal $jobid";
    my $status = "Signal sending request registered"; 

    my $cmdRes = OAR::API::send_cmd($cmd,"Oar");
    print $q->header( -status => 202, -type => "$type" );
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export( { 'id' => "$jobid",
                    'status' => "$status",
                    'cmd_output' => "$cmdRes",
                    'api_timestamp' => time()
                  } , $ext );
    last;
  };
  #}}}
  #
  #{{{ POST /jobs : A new job (oarsub wrapper)
  #
  $URI = qr{^/jobs\.*(yaml|json|html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext=OAR::API::set_ext($q,$1);
    (my $header, my $type)=OAR::API::set_output_format($ext,"GET, POST");

    # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before posting jobs" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    # Check and get the submitted job
    # From encoded data
    my $job;
    if ($q->param('POSTDATA')) {
      $job = OAR::API::check_job( $q->param('POSTDATA'), $q->content_type );
    }
    # From html form
    else {
      $job = OAR::API::check_job( $q->Vars, $q->content_type );
    }

    # Make the query (the hash is converted into a list of long options)
    my $oarcmd = "$OARSUB_CMD ";
    my $workdir = "~$authenticated_user";
    my $command = "";
    my $script = "";
    my $param_file = "";
    my $tmpfilename = "";
    my $tmpparamfilename = "";
    foreach my $option ( keys( %{$job} ) ) {
      if ($option eq "script_path") {
        $job->{script_path} =~ s/(\\*)"/$1$1\\"/g;
        $command = " \"$job->{script_path}\"";
      }
      elsif ($option eq "command") {
        # Escapes double quotes
        $job->{command} =~ s/(\\*)"/$1$1\\"/g;
        $command = " \"$job->{command}\"";
      }
      elsif ($option eq "script") {
        $script = $job->{script};
      }
      elsif ($option eq "param_file") {
        $param_file = $job->{param_file};
      }
      elsif ($option eq "workdir") {
        $workdir = $job->{workdir};
      }
      elsif ($option eq "resources") {
        $oarcmd .= " --resource=$job->{resources}";
      }
      elsif (ref($job->{$option}) eq "ARRAY") {
        foreach my $elem (@{$job->{$option}}) {
          $oarcmd .= " --$option";
          # Escapes double quotes
          $elem =~ s/(\\*)"/$1$1\\"/g;
          $oarcmd .= "=\"$elem\"" if $elem ne "";
         }
      }
      else {
        $oarcmd .= " --$option";
        # Escapes double quotes
        $job->{$option}=~ s/(\\*)"/$1$1\\"/g;
        $oarcmd .= "=\"$job->{$option}\"" if $job->{$option} ne "";
      }
    }
    $oarcmd .= $command;
    # Escapes double quotes (one more time, for oardodo)
    $oarcmd =~ s/(\\*)"/$1$1\\"/g;
    my $cmd;

    # If a parameters file is provided, we create a temporary file
    # and write the parameters inside.
    if ($param_file ne "") {
      my $TMP;
      ($TMP, $tmpparamfilename) = tempfile( "oarapi.paramfile.XXXXX", DIR => $TMPDIR, UNLINK => 1 );
      print $TMP $param_file;
      $oarcmd .= " --array-param-file=$tmpparamfilename";
    }

    # If a script is provided, we create a file into the workdir and write
    # the script inside.
    if ($script ne "") {
      my $TMP;
      ($TMP, $tmpfilename) = tempfile( "oarapi.subscript.XXXXX", DIR => $TMPDIR, UNLINK => 1 );
      print $TMP $script;
      # This is probably the most annoying thing about this trick:
      # the tmp file (owned by oar at this stage) has to be readable by the user. 
      # So, the user should be warned that his script may be public. 
      # We could make it owned by the user, with a OARDODO call, but it has a
      # performance cost.
      chmod 0755, $tmpfilename;
      $oarcmd .= " ./". basename($tmpfilename);
      $cmd = "$OARDODO_CMD bash --noprofile --norc -c \"cp $tmpfilename $workdir/ && cd $workdir && $oarcmd\"";
    }else{ 
      $cmd = "$OARDODO_CMD bash --noprofile --norc -c \"cd $workdir && $oarcmd\"";
    }
    # Escapes some special characters (especially security fix with backquote)
    $cmd =~ s/(\\*)(`|\$)/$1$1\\$2/g;
    my $cmdRes = `$cmd 2>&1`;
    unlink $tmpfilename;
    unlink $tmpparamfilename;
    if ( $? != 0 ) {
      my $err = $? >> 8;
      # Error codes corresponding to an error into the user's request
      if ( $err == 6 || $err == 4 || $err == 5 || $err == 7 
            || $err == 17 || $err == 16 || $err == 6
            || $err == 8 || $err == 10 ) {
        OAR::API::ERROR(
          400,
          "Bad query",
          "Oarsub command exited with status $err: $cmdRes\nCmd:\n$oarcmd"
        );
      }else{
        OAR::API::ERROR(
          500,
          "Oar server error",
          "Oarsub command exited with status $err: $cmdRes\nCmd:\n$oarcmd"
        );
      }
    }
    elsif ( $cmdRes =~ m/.*JOB_ID\s*=\s*(\d+).*/m ) {
      my $uri=OAR::API::htmlize_uri(OAR::API::make_uri("jobs/$1",$ext,0),$ext);
      my $abs_uri=OAR::API::make_uri("jobs/$1",$ext,1);
      print $q->header( -status => 201, -type => "$type" , -location => $abs_uri );
      print $HTML_HEADER if ($ext eq "html");
      print OAR::API::export( { 'id' => int($1),
                      'links' => [ { 'href' => $uri,
                                     'rel' => "self"} ],
                      'api_timestamp' => time(),
                      'cmd_output' => "$cmdRes",
                    } , $ext );
    }
    else {
      OAR::API::ERROR( 500, "Parse error",
        "Job submitted but the id could not be parsed.\nCmd:\n$oarcmd" );
    }
    last;
  };
  #}}}
  #
  #{{{ DELETE /jobs/<id> : Delete a job (oardel wrapper)
  #
  $URI = qr{^/jobs/(\d+)(\.yaml|\.json|\.html)*$};
  OAR::API::DELETE( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $jobid = $1;
    my $ext=OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);

    # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
       "A suitable authentication must be done before deleting jobs" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    my $cmd    = "$OARDODO_CMD $OARDEL_CMD $jobid";
    my $cmdRes = OAR::API::send_cmd($cmd,"Oardel");
    print $q->header( -status => 202, -type => "$type" );
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export( { 'id' => "$jobid",
                    'status' => "Delete request registered",
                    'oardel_output' => "$cmdRes",
                    'api_timestamp' => time()
                  } , $ext );
    last;
  };
  #}}}
  #
  #{{{       /jobs/stagein and stageout (desktop computing)
  #
  $URI = qr{^/jobs/(\d+)/stagein(.tar\.gz|.tgz)$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    OAR::API::jobStageIn($1);

    last;
  };

  $URI = qr{^/jobs/(\d+)/stagein(.tar\.gz|.tgz)$};
  OAR::API::HEAD( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    OAR::API::jobStageInHead($1);
    last;
  };

  $URI = qr{^/jobs/(\d+)/stageout(.tar\.gz|.tgz)$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext,"GET, POST");
    my $fh = $q->upload('myfile');
    if (defined $fh) {
        my $io_handle = $fh->handle;
        my $buffer;
        open (OUTFILE, '>>', "$stageout_dir/$1.tgz");
        while (my $bytesread = $io_handle->read($buffer, 1024)) {
          print OUTFILE $buffer;
        }
    }
    print $q->header( -status => 200, -type => "application/x-tar" );
    last;
  };
  #}}}
  #
  #{{{ POST /jobs/<id>/state : changes the state of a job
  #
  $URI = qr{^/jobs/(\d+)/state(.*)$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext,"GET, POST");
    print $q->header( -status => 200, -type => $type );
    my $json = decode_json $q->param('POSTDATA');
    my $state = $json->{'state'};
    if ($state eq 'running'){
        OAR::API::runJob($1);
    } elsif($state eq 'terminated'){
        OAR::API::terminateJob($1);
    } elsif($state eq 'error'){
        OAR::API::errorJob($1);
    } else {
        die "unknown state"
    }
    last;
  };
  #}}}

  ###########################################
  # Resources
  ###########################################
  #
  #{{{ GET /resources/(full|<id>) : List of resources or details of a resource
  #
  $URI = qr{^/resources(/full|/[0-9]+)*\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext=OAR::API::set_ext($q,$2);
    my $header, my $type;
    if(defined($1)) {
      if ($1 ne "/full") {
        ($header, $type)=OAR::API::set_output_format($ext,"GET, DELETE");
      }else{
        ($header, $type)=OAR::API::set_output_format($ext,"GET");
      }
    }else{
      ($header, $type)=OAR::API::set_output_format($ext,"GET, POST");
    }
 
    # will the resources need be paged or not
    # by default resources results are paged
    my $paged = 1;
    my $compact = 0;
    
    # GET limit from uri parameter
    if (defined($q->param('limit'))) {
        $MAX_ITEMS = $q->param('limit');
    }
    # set offset / GET offset from uri parameter
    my $offset = 0;
    if (defined($q->param('offset'))) {
        $offset = $q->param('offset');
    }
    
    my $resources;
    OAR::Nodes::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    if (defined($1)) {
    	if ($1 eq "/full") {
    		# get specified intervals of resources
    		$resources = OAR::Nodes::get_requested_resources($MAX_ITEMS,$offset);
    	}
        elsif ($1 =~ /\/([0-9]+)/)  {
        	# get the resources infos
        	my $resource = OAR::Nodes::get_resource_infos($1);
        	if (defined($resource)) {
        		$resources = [OAR::Nodes::get_resource_infos($1)];
        	}
        	else {
        		# resource does not exist
        		#$resources = OAR::API::struct_empty($STRUCTURE);
                        OAR::API::ERROR( 404, "Resource not found",
                        "Resource not found" );
        	}
        	
        	# do not need to paging resource detail
        	$paged = 0;
                $compact = 1;
        }
        else {
        	OAR::API::ERROR(500,"Error 666!","Error 666");           
        }
    }
    else
    {
    	# get specified intervals of resources
    	$resources = OAR::Nodes::get_requested_resources($MAX_ITEMS,$offset); 
        $resources = OAR::API::filter_resource_list($resources); 
    }
    OAR::API::fix_resource_ids($resources);
    OAR::API::add_resources_uris($resources,$ext,'');
    $resources = OAR::API::struct_resource_list($resources,$STRUCTURE,$compact);
    
    # test if resources need to be paged
    if ($paged == 1) {
    	# get the total number of resources
    	my $total_resources = OAR::Nodes::count_all_resources();
    	# add pagination informations
    	$resources = OAR::API::add_pagination($resources,$total_resources,$q->path_info,$q->query_string,$ext,$MAX_ITEMS,$offset,$STRUCTURE);
    }
    OAR::Nodes::close_db_connection;

    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($resources,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /resources/nodes/<node> : List the resources of a node
  #
  $URI = qr{^/resources/nodes/([\w\.-]+?)(\.yaml|\.json|\.html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext=OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    OAR::Nodes::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $resources = OAR::Nodes::get_resources_for_host($1);
    $resources = OAR::API::filter_resource_list($resources);
    OAR::Nodes::close_db_connection;
    OAR::API::add_resources_uris($resources,$ext,'');
    $resources = OAR::API::struct_resource_list($resources,$STRUCTURE,0);
    $resources = OAR::API::add_pagination($resources,@$resources,$q->path_info,undef,$ext,0,0,$STRUCTURE);
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($resources,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /resources/jobs : (NOT YET IMPLEMENTED) Jobs running on all resources
  #
  # TODO: should give an array of all resources plus a job array per resource
  #}}}
  #
  #{{{ GET /resources/(<id>)/jobs : Jobs running on a resource
  #
  $URI = qr{^/resources(/[0-9]+)+/jobs(\.yaml|\.json|\.html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext=OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    OAR::Nodes::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $jobs;
    if ($1 =~ /\/([0-9]+)/)  { 
        my $job_array=OAR::Nodes::get_jobs_running_on_resource($1);
        foreach my $job_id (@$job_array) {
          push(@$jobs,{id =>int($job_id)});
        }
        OAR::API::add_jobs_on_resource_uris($jobs,$ext); 
    }
    OAR::Nodes::close_db_connection;
    $jobs = OAR::API::add_pagination($jobs,@$jobs,$q->path_info,undef,$ext,0,0,$STRUCTURE);
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($jobs,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /resources/nodes/<node>/jobs : Jobs running on a node
  #
  $URI = qr{^/resources/nodes/([-\.\w]+)/jobs(.*)$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);
    OAR::Nodes::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $jobs;
    my $job_array;

    #OAR::Nodes::heartbeat($1); <-- what the hell is that????

    # a "?state=" filter is possible, but prevent Terminated and Error state
    # because this result is not paginated and output may be too big
    if (defined($q->param('state')) && $q->param('state') eq "toKill"){
      # This "toKill" state is virtual and implemented for the desktop
      # computing agent purpose.
      $job_array=OAR::Nodes::get_jobs_running_on_node($1);

      foreach my $job_id (@$job_array) {
        push(@$jobs,{id =>int($job_id)}) if OAR::Nodes::is_job_tokill($job_id);
      }
    }
    elsif (defined($q->param('state')) && $q->param('state') ne "Terminated"
                                    && $q->param('state') ne "Error" ) {
      $job_array=OAR::Nodes::get_jobs_on_node($1,$q->param('state'));

      foreach my $job_id (@$job_array) {
        push(@$jobs,{id =>int($job_id)});
      }
    }else{
      $job_array=OAR::Nodes::get_jobs_running_on_node($1);

      foreach my $job_id (@$job_array) {
        push(@$jobs,{id =>int($job_id)});
      }
    } 
    OAR::API::add_jobs_on_resource_uris($jobs,$ext); 
    OAR::Nodes::close_db_connection;
    $jobs = OAR::API::add_pagination($jobs,@$jobs,$q->path_info,undef,$ext,0,0,$STRUCTURE);
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($jobs,$ext);
    last;
  };
  #}}}
  #
  #{{{ POST /resources : Create new resources
  # 
  $URI = qr{^/resources(\.yaml|\.json|\.html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext=OAR::API::set_ext($q,$1);
    (my $header)=OAR::API::set_output_format($ext,"GET, POST");

    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before creating new resources" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can create new resources" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";
  
    # Check and get the submited resource
    # From encoded data
    my $resources;
    if ($q->param('POSTDATA')) {
      $resources = OAR::API::check_resources( $q->param('POSTDATA'), $q->content_type );
    }
    # From html form
    else {
      $resources = OAR::API::check_resources( $q->Vars, $q->content_type );
    }

    my $dbh = OAR::IO::connect() or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my @ids=OAR::IO::add_resources($dbh,$resources) or OAR::API::ERROR(500,
                                                "Could not create asked resources",
                                                "Could not create asked resources"
                                                 );
    if ($ids[0] =~ /^Error.*/) {
      OAR::API::ERROR(500,"SQL query failed into resources creation",$ids[0]);
    } 
    my $result=[];
    foreach my $id (@ids) {
      push(@$result,{ id => $id, links => [ { rel => "self", href => "resources/$id" } ] });
    }
    $result = OAR::API::add_pagination($result,@ids,$q->path_info,$q->query_string,$ext,0,0,$STRUCTURE);
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export( $result , $ext );
    OAR::Tools::notify_tcp_socket($remote_host,$remote_port,"ChState");
    OAR::Tools::notify_tcp_socket($remote_host,$remote_port,"Term");
    OAR::IO::disconnect($dbh);
    last;
  }; 
  #}}}
  #
  #{{{ POST /resources/<id>/state : Change the state of a resource
  # 
  $URI = qr{^/resources/(\d+)/state(\.yaml|\.json|\.html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $id=$1;
    my $ext=OAR::API::set_ext($q,$2);
    (my $header)=OAR::API::set_output_format($ext,"GET, POST");

    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before creating new resources" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can create new resources" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";
  
    # Check and get the submited resource
    # From encoded data
    my $resource;
    if ($q->param('POSTDATA')) {
      $resource = OAR::API::check_resource_state( $q->param('POSTDATA'), $q->content_type );
    }
    # From html form
    else {
      $resource = OAR::API::check_resource_state( $q->Vars, $q->content_type );
    }

    my $dbh = OAR::IO::connect() or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    OAR::IO::set_resource_state($dbh,$id,$resource->{state},"NO");
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export( { 
                      'status' => "Change state request registered",
                      'id' => "$id",
                      'api_timestamp' => time(),
                      'uri' => OAR::API::htmlize_uri(OAR::API::make_uri("resources/$id",$ext,0),$ext)
                    } , $ext );
    OAR::Tools::notify_tcp_socket($remote_host,$remote_port,"ChState");
    OAR::Tools::notify_tcp_socket($remote_host,$remote_port,"Term");
    OAR::IO::disconnect($dbh);
    last;
  }; 
  #}}}
  #
  #{{{ DELETE /resources/(<id>|<node>/<cpuset) : Delete a resource (by id or node+cpuset)
  #
  $URI = qr{^/resources/([\w\.-]+?)(/\d)*(\.yaml|\.json|\.html)*$};
  OAR::API::DELETE( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $id;
    my $node;
    my $cpuset;
    if ($2) { $node=$1; $id=0; $cpuset=$2; $cpuset =~ s,^/,, ;}
    else    { $node=""; $id=$1; $cpuset=""; } ;
    my $ext=OAR::API::set_ext($q,$3);
    (my $header)=OAR::API::set_output_format($ext);

    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before deleting new resources" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can delete resources" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";

    my $base = OAR::IO::connect() or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
 
    # Check if the resource exists
    my $query;
    my $Resource;
    if ($id == 0) {
      $query="WHERE network_address = \"$node\" AND cpuset = $cpuset";
    }
    else {
      $query="WHERE resource_id=$id";
    }
    my $sth = $base->prepare("SELECT resource_id FROM resources $query");
    $sth->execute();
    my @res = $sth->fetchrow_array();
    if ($res[0]) { $Resource=$res[0];}
    else { 
      OAR::API::ERROR(404,"Not found","Corresponding resource could not be found ($id,$node,$cpuset)");
      last;
    }

    # Resource deletion
    # !!! This is a dirty cut/paste of oarremoveresource code !!!
    my $resource_ref = OAR::IO::get_resource_info($base,$Resource);
    if (defined($resource_ref->{state}) && ($resource_ref->{state} eq "Dead")){
      my $sth = $base->prepare("  SELECT jobs.job_id, jobs.assigned_moldable_job
                                  FROM assigned_resources, jobs
                                  WHERE
                                      assigned_resources.resource_id = $Resource
                                      AND assigned_resources.moldable_job_id = jobs.assigned_moldable_job
                               ");
      $sth->execute();
      my @jobList;
      while (my @ref = $sth->fetchrow_array()) {
          push(@jobList, [$ref[0], $ref[1]]);
      }
      $sth->finish();
      foreach my $i (@jobList){
        $base->do("DELETE from event_logs         WHERE job_id = $i->[0]");
        $base->do("DELETE from frag_jobs          WHERE frag_id_job = $i->[0]");
        $base->do("DELETE from jobs               WHERE job_id = $i->[0]");
        $base->do("DELETE from assigned_resources WHERE moldable_job_id = $i->[1]");
      }
      $base->do("DELETE from assigned_resources     WHERE resource_id = $Resource");
      $base->do("DELETE from resource_logs          WHERE resource_id = $Resource");
      $base->do("DELETE from resources              WHERE resource_id = $Resource");
      #print("Resource $Resource removed.\n");
      print $header;
      print $HTML_HEADER if ($ext eq "html");
      print OAR::API::export( { 'status' => "deleted",'api_timestamp' => time() } , $ext );
    }else{
      OAR::API::ERROR(403,"Forbidden","The resource $Resource must be in the Dead status"); 
      last;
    }
    last;
  };
  #}}}
  # 
  #{{{ POST /resources/generate : Generate resources ('oaradmin re -a -Y' wrapping)
  #
  $URI = qr{^/resources/generate(\.yaml|\.json|\.html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$1);
    (my $header) = OAR::API::set_output_format($ext,"GET, POST");

    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before generating resources" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can generate resources" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";

    # Check and get the submited resource description
    # From encoded data
    my $description;
    
    # command generation
    my $cmd;    
    # ressources properties
    my $cmd_properties="";
    
    if ($q->param('POSTDATA')) {
      $description = OAR::API::check_resource_description( $q->param('POSTDATA'), $q->content_type );
      # getting properties
      if (defined($description->{properties})) {
    	foreach my $property ( keys %{$description->{properties}} ) {
    		$cmd_properties .= " -p ".$property."=".$description->{properties}->{$property}
        }
      }
    }
    # From html form
    else {
      $description = OAR::API::check_resource_description( $q->Vars, $q->content_type );
      # getting properties
      if (defined($description->{properties})) {
      	my @properties = split(/,/,$description->{properties});
      	foreach my $property (@properties) {
      		$cmd_properties .= " -p $property";
      	}
      }
    }

    my $auto_offset="";
    if (defined($description->{auto_offset}) && "$description->{auto_offset}" eq "1") {
      $auto_offset="--auto-offset ";
    }
    # command with arguments
    $cmd = "PATH=\$PATH:/usr/sbin:/usr/local/sbin $OARADMIN_CMD resources -a -Y $auto_offset".$description->{resources}.$cmd_properties;
    # execute the command
    my $cmdRes = OAR::API::send_cmd($cmd,"Oar");
    my $data = OAR::API::import_data($cmdRes,"yaml");
    OAR::API::struct_resource_list_fix_ints($data);
    $data = OAR::API::add_pagination($data,@$data,$q->path_info,undef,$ext,0,0,$STRUCTURE);
    print $header;
    if ($ext eq "html") {
      print $HTML_HEADER;
      api_uri::resources_commit_button($data->{"items"});
    }
    print OAR::API::export($data,$ext);
    last;
  };
  #}}}

  ###########################################
  # Admission rules 
  ###########################################
  #
  #{{{ GET /admission_rules : List of all admissions rules
  #
  $URI = qr{^/admission_rules\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
  	$_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$1);
    (my $header, my $type) = OAR::API::set_output_format($ext);
    
    # GET limit from uri parameter
    if (defined($q->param('limit'))) {
        $MAX_ITEMS = $q->param('limit');
    }
    # set offset / GET offset from uri parameter
    my $offset = 0;
    if (defined($q->param('offset'))) {
        $offset = $q->param('offset');
    }
    OAR::Stat::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                          );
    # get specified intervals of admission rules
    my $admissions_rules = OAR::Stat::get_requested_admission_rules($MAX_ITEMS,$offset);
    
    OAR::API::add_admission_rules_uris($admissions_rules,$ext);
    $admissions_rules = OAR::API::struct_admission_rule_list($admissions_rules,$STRUCTURE);
    
    # get the total number of admissions rules
    my $total_rules = OAR::Stat::count_all_admission_rules();
    OAR::Stat::close_db_connection();
    
    # add pagination informations
    $admissions_rules = OAR::API::add_pagination($admissions_rules,$total_rules,$q->path_info,$q->query_string,$ext,$MAX_ITEMS,$offset,$STRUCTURE);
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($admissions_rules,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /admission_rules/<id> : Details of an admission rule
  #
  $URI = qr{^/admission_rules/(\d+)(\.yaml|\.json|\.html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $rule_id = $1;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);
 
    OAR::Stat::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $admission_rule = OAR::Stat::get_specific_admission_rule($rule_id);
    OAR::API::add_admission_rule_uris($admission_rule,$ext);
    $admission_rule = OAR::API::struct_admission_rule($admission_rule,$STRUCTURE);

    OAR::Stat::close_db_connection; 
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($admission_rule,$ext);
    last;
  };
  #}}}
  #
  #{{{ POST /admission_rules : Create a new admission rule
  # 
  $URI = qr{^/admission_rules(\.yaml|\.json|\.html)*$};
  (OAR::API::POST( $_, $URI ) || OAR::API::PUT( $_, $URI )) && do {
    $_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$1);
    (my $header) = OAR::API::set_output_format($ext,"GET, POST");

    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before creating new admission rules" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can create new admission rules" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";
  
    # Check and get the submited admission rule
    # From encoded data
    my $admission_rule;

    if ($q->param('POSTDATA')) {
      $admission_rule = OAR::API::check_admission_rule( $q->param('POSTDATA'), $q->content_type );
    }
    elsif ($q->param('PUTDATA')) {
      $admission_rule = OAR::API::check_admission_rule( $q->param('PUTDATA'), $q->content_type );
    }
    # From html form
    else {
      $admission_rule = OAR::API::check_admission_rule( $q->Vars, $q->content_type );
    }

    OAR::Stat::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $id = OAR::Stat::add_admission_rule($admission_rule->{rule});
    if ( $id && $id > 0) {
      	print $header;
      	print $HTML_HEADER if ($ext eq "html");
      	print OAR::API::export( { 
                      'id' => "$id",
                      'rule' => OAR::API::nl2br($admission_rule->{rule}),
                      'api_timestamp' => time(),
                      'uri' => OAR::API::htmlize_uri(OAR::API::make_uri("admission_rules/$id",$ext,0),$ext)
                    } , $ext );
      	OAR::Stat::close_db_connection; 
    }
    else {
      OAR::API::ERROR(
        500,
        "Admission rule not created",
        "Could not create the new admission rule"
      );
    }
    last;
  };
  #}}}
  #
  #{{{ DELETE /admission_rules/<id> : Delete an admission rule
  #
  $URI = qr{^/admission_rules/(\d+)(\.yaml|\.json|\.html)*$};
  OAR::API::DELETE( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $rule_id = $1;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type)=OAR::API::set_output_format($ext);

    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before deleting an admission rule" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can delete admission rules" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;
    

    OAR::Stat::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $admission_rule = OAR::Stat::get_specific_admission_rule($rule_id);
    print $header;
    if (defined($admission_rule)) {
    	OAR::Stat::delete_specific_admission_rule($rule_id);
    	print $HTML_HEADER if ($ext eq "html");
    	print OAR::API::export( { 'id' => "$admission_rule->{id}",
    				            'rule' => "$admission_rule->{rule}",
                    			'status' => "deleted",
                    			'api_timestamp' => time()
    						  } , $ext );
        OAR::Stat::close_db_connection; 
    }
    else {
    	OAR::API::ERROR(404,"Not found","Corresponding admission rule could not be found");
    }
    last;
  };
  #}}}
  #
  #{{{ POST /admission_rules/<id>?method=delete : Delete an admission rule
  # Should not be used unless for delete from an http browser
  # (better to use the URI above)
  #
  $URI = qr{^/admission_rules/(\d+)(\.yaml|\.json|\.html)*$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $rule_id = $1;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type) = OAR::API::set_output_format($ext,"GET, POST");
 
     # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before deleting an admission rule" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;
    
    OAR::Stat::open_db_connection or OAR::API::ERROR(500, 
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    # Check and get the submitted data
    # From encoded data
    my $admission_rule;
    if ($q->param('POSTDATA')) {
      $admission_rule = OAR::API::check_admission_rule_update( $q->param('POSTDATA'), $q->content_type );
    }
    # From html form
    else {
      $admission_rule = OAR::API::check_admission_rule_update( $q->Vars, $q->content_type );
    }

    # Delete (alternative way to DELETE request, for html forms)
    print $header;
    if ($admission_rule->{method} eq "delete" ) {
    	OAR::Stat::delete_specific_admission_rule($rule_id);
    	print $HTML_HEADER if ($ext eq "html");
    	print OAR::API::export( { 'id' => "$rule_id",
                    			'status' => "deleted",
                    			'api_timestamp' => time()
    						  } , $ext );
        OAR::Stat::close_db_connection;
    }
    else {
      OAR::API::ERROR(400,"Bad query","Could not understand ". $admission_rule->{method} ." method");
    }
    last;
  };
  #}}}

  ###########################################
  # Config file edition 
  ###########################################
  #
  #{{{ GET /config : List of all the configured variables
  #
  $URI = qr{^/config\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
  	$_->path_info =~ m/$URI/;
    my $ext = OAR::API::set_ext($q,$1);
    (my $header, my $type) = OAR::API::set_output_format($ext);
    
    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before getting configuration parameters" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can get configuration parameters" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";

    # get all configured parameters
    my $list_params = get_conf_list();
    # parameters hash result
    my $parameters;

    if ( !defined $list_params || keys %$list_params == 0 ) {
      $parameters = OAR::API::struct_empty($STRUCTURE);
    }
    else {
    	foreach my $param (keys %$list_params) {
    		$parameters->{$param}->{value} =  $list_params->{$param};
    	}
    	OAR::API::add_config_parameters_uris($parameters,$ext);
    	$parameters = OAR::API::struct_config_parameters_list($parameters,$STRUCTURE);
    }

    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($parameters,$ext);
    last;
  };
  #}}}
  #
  #{{{ GET /config/<variable_name> : Get a configuration variable value
  #
  $URI = qr{^/config/(\w+)\.(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
  	$_->path_info =~ m/$URI/;
  	my $variable = $1;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type) = OAR::API::set_output_format($ext);
    
    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before getting configuration parameters" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can get configuration parameters" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";

    # result parameter
    my $parameter;
    if (is_conf($variable)) {
    	$parameter->{id} = $variable;
    	$parameter->{value} = get_conf($variable);
    	OAR::API::add_config_parameter_uris($parameter,$ext);
    	$parameter = OAR::API::struct_config_parameter($parameter,$STRUCTURE);
    }
    else {
    	$parameter->{id} = OAR::API::struct_empty($STRUCTURE);
    }

    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($parameter,$ext);
    last;
  };
  #}}}
  #
  #{{{ POST /config/<variable_name> : Change the value of a configuration parameter
  #
  $URI = qr{^/config/(\w+)\.(yaml|json|html)*$};
  OAR::API::POST( $_, $URI ) && do {
  	$_->path_info =~ m/$URI/;
  	my $variable = $1;
    my $ext = OAR::API::set_ext($q,$2);
    (my $header, my $type) = OAR::API::set_output_format($ext,"GET, POST");
    
    print $header;
    print $HTML_HEADER if ($ext eq "html");
    
    # Must be administrator (oar user)
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before changing configuration parameters" );
      last;
    }
    if ( not $authenticated_user eq "oar" ) {
      OAR::API::ERROR( 401, "Permission denied",
        "Only the oar user can make changes on configuration parameters" );
      last;
    }
    $ENV{OARDO_BECOME_USER} = "oar";

    # configuration parameter
    my $parameter;

    if ($q->param('POSTDATA')) {
      $parameter = OAR::API::check_configuration_variable( $q->param('POSTDATA'), $q->content_type );
    }
    # From html form
    else {
      $parameter = OAR::API::check_configuration_variable( $q->Vars, $q->content_type );
    }

    my $result;
    if (is_conf($variable)) {
    	set_value($variable, $parameter->{value});
    	$result->{$variable} = $parameter;
    }
    else {
    	$result->{$variable} = OAR::API::struct_empty($STRUCTURE);
    }

    print OAR::API::export($result,$ext);
    last;
  };
  #}}}

  ###########################################
  # Desktop computing specific
  ###########################################
  #
  #{{{ GET /desktop/agents : Desktop computing agent sign in
  #
  $URI = qr{^/desktop/agents(.*)$};
  OAR::API::GET( $_, $URI ) && do {

    my $db = OAR::IO::connect() or die "cannot connect to the data base\n";

    OAR::IO::lock_table($db,["event_logs"]);
    my $result = OAR::IO::get_last_event_from_type($db, "NEW_VIRTUAL_HOSTNAME");
    if ($result) {
      $result = $result->{'description'};
      $result++;
      OAR::API::sign_in($result,$remote_host,$remote_port,$expiry,$allow_create_node);
      OAR::IO::add_new_event($db,"NEW_VIRTUAL_HOSTNAME",0,$result);
      $result = {'hostname' => $result};
    } else {
      OAR::API::sign_in('vnode1',$remote_host,$remote_port,$expiry,$allow_create_node);
      OAR::IO::add_new_event($db,"NEW_VIRTUAL_HOSTNAME",0,'vnode1');
      $result = {'hostname' => 'vnode1'};
    }

    OAR::IO::unlock_table($db);
    # TODO: reject if DESKTOP_COMPUTING_ALLOW_CREATE_NODE="0"
    print $q->header( -status => 200, -type => "application/json" );
    print OAR::API::export($result,'json');

    last;
  };
  #}}}

  ###########################################
  # Media (files) download/upload
  ###########################################
  #
  #{{{ GET /media/<file> : Get a file
  #
  $URI = qr{^/media/(.*)$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $filename=$1;

    # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before getting files" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    # Security escaping 
    $filename =~ s/(\\*)(`|\$)/$1$1\\$2/g;

    # Get the filename and replace "~" by the home directory
    my $file="/".$filename;
    my @user_infos=getpwnam($authenticated_user);
    $file =~ s|/~/|$user_infos[7]/|;  
 
    # Check file existency
    if (system("$OARDODO_CMD","test","-f","$file") != 0) {
      OAR::API::ERROR(404, "Not found", "File not found: $file");
      last;  
    }
    
    # Check file readability
    if (system("$OARDODO_CMD","test","-r","$file") != 0) {
      OAR::API::ERROR(403, "Forbidden","File could not be read: $file" );
      last;  
    }

    # Output the file
    print $q->header( -status => 200, -type => "application/octet-stream" );
    print `$OARDODO_CMD cat $file`;
    last;
  };
  #}}}
  #
  #{{{ POST /media/<file> : Upload a file and create underlying directories
  #
  $URI = qr{^/media/(.*)$};
  OAR::API::POST( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $filename=$1;

    # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before getting files" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    # Security escaping 
    $filename =~ s/(\\*)(`|\$)/$1$1\\$2/g;

    # Get the filename and replace "~" by the home directory
    my $file="/".$filename;
    my @user_infos=getpwnam($authenticated_user);
    $file =~ s|/~/|$user_infos[7]/|;  

    # Create the directories if necessary
    my $path=dirname($file);
    if (system("$OARDODO_CMD","mkdir","-p",$path) != 0) {
      OAR::API::ERROR(500, "mkpath error", "Problem while creating path: $path");
      last; 
    }

    # Upload the file if any 
    #my $fh = $q->upload('file');
    #if (defined $fh) {
    #    my $io_handle = $fh->handle;
    #    my $buffer;
    #    open (OUTFILE, "|", "$OARDODO_CMD bash --noprofile --norc -c \"cat > $file\"");
    #    while (my $bytesread = $io_handle->read($buffer, 1024)) {
    #      print OUTFILE $buffer;
    #    }
    #    close(OUTFILE);
    if ($q->param('POSTDATA')) {
      if (system("$OARDODO_CMD","touch",$file) != 0) {
        OAR::API::ERROR(500, "write error", "Error creating file: $file");
        close(OUTFILE);
        last; 
      }
      open (OUTFILE, "|$OARDODO_CMD bash --noprofile --norc -c \"cat > $file\"");
      print OUTFILE $q->param('POSTDATA');
      close(OUTFILE);
    }else{
        # If no file is given, then create an empty one
        `$OARDODO_CMD touch $file`;
    }
    print $q->header( -status => 201, -type => "application/octet-stream" , -location => "/media/$file" );
    last;
  };
  #}}}
  #
  #{{{ DELETE /media/<file> : Delete a file or a directory recursively
  #
  $URI = qr{^/media/(.*)$};
  OAR::API::DELETE( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $filename=$1;

    # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before getting files" );
      last;
    }
    $authenticated_user = $1;
    $ENV{OARDO_BECOME_USER} = $authenticated_user;

    # Security escaping 
    $filename =~ s/(\\*)(`|\$)/$1$1\\$2/g;

    # Get the filename and replace "~" by the home directory
    my $file="/".$filename;
    my @user_infos=getpwnam($authenticated_user);
    $file =~ s|/~/|$user_infos[7]/|;  
 
    # Check file existency
    if (system("$OARDODO_CMD","test","-e","$file") != 0) {
      OAR::API::ERROR(404, "Not found", "File not found: $file");
      last;  
    }
    
    # Check file readability
    if (system("$OARDODO_CMD","test","-w","$file") != 0) {
      OAR::API::ERROR(403, "Forbidden","File or directory is not writeable: $file" );
      last;  
    }

    # Delete the file
    print $q->header( -status => 204, -type => "application/octet-stream" );
    print `$OARDODO_CMD rm -rf $file`;
    last;
  };
  #}}}
  
  ###########################################
  # SQL queries
  ###########################################
  # 
  #{{{ GET /select_all?query=<query>) : Allows select SQL queries into the OAR database (ro) 
  #
  $URI = qr{^/select_all\.*(yaml|json|html)*$};
  OAR::API::GET( $_, $URI ) && do {
    $_->path_info =~ m/$URI/;
    my $ext=OAR::API::set_ext($q,$1);
    my $header, my $type;
    ($header, $type)=OAR::API::set_output_format($ext,"GET");

    # Must be authenticated
    if ( not $authenticated_user =~ /(\w+)/ ) {
      OAR::API::ERROR( 401, "Permission denied",
        "A suitable authentication must be done before looking at jobs" );
      last;                                     
    }                                     
    $authenticated_user = $1;
    $ENV{OARDO_USER} = $authenticated_user;

    my $query;
    # GET the query parameter from the uri
    if (defined($q->param('query'))) {
        $query = $q->param('query');
    }else{
      OAR::API::ERROR(400,"Bad query","The 'query' parameter is mandatory");
    }

    # GET limit from uri parameter
    my $limit;
    if (defined($q->param('limit'))) {
        $limit = $q->param('limit');
    }else{
        $limit=$MAX_ITEMS;
    }

    # set offset / GET offset from uri parameter
    my $offset = 0;
    if (defined($q->param('offset'))) {
        $offset = $q->param('offset');
    }
   
    # Do the query
    # The query should not contain the "SELECT <something> part". Example:
    #  query="FROM events,jobs WHERE ..." 
    my $dbh = OAR::IO::connect_ro() or OAR::API::ERROR(500,
                                                "Cannot connect to the database",
                                                "Cannot connect to the database"
                                                 );
    my $count = OAR::IO::sql_count($dbh,$query) or OAR::API::ERROR(500,
                                                "SQL error",
                                                "SQL error" # <- add here the sql error output
                                                 ); 
    my $result = OAR::IO::sql_select($dbh,$query,$limit,$offset) or OAR::API::ERROR(500,
                                                "SQL error",
                                                "SQL error" # <- add here the sql error output
                                                 );

    #$result = OAR::API::format_select_result($result);
    $result = OAR::API::add_pagination($result,$count,$q->path_info,$q->query_string,$ext,$limit,$offset,$STRUCTURE);

    print $header;
    print $HTML_HEADER if ($ext eq "html");
    print OAR::API::export($result,$ext);
    last;
  };
  #}}}

  ###########################################
  # Html stuff
  ###########################################
  #
  #{{{ GET /index : Welcome page (html only)
  #
  $URI = qr{^/index\.html$};
  OAR::API::GET( $_, $URI ) && do {
    print $q->header( -status => 200, -type => "text/html" );
    print $HTML_HEADER;
    print "Welcome on the oar API\n";
    last;
  };
  #}}}
  #
  #{{{ GET /jobs/form : Html form for job posting
  #
  $URI = qr{^/jobs/form.html$};
  OAR::API::GET( $_, $URI ) && do {
    (my $header, my $type)=OAR::API::set_output_format("html");
    print $header;
    print $HTML_HEADER;
    my $POSTFORM="";
    my $file;
    if (is_conf("API_HTML_POSTFORM")){ $file=get_conf("API_HTML_POSTFORM"); }
    else { $file="/etc/oar/api_html_postform.pl"; }
    open(FILE,$file);
    my(@lines) = <FILE>;
    eval join("\n",@lines);
    close(FILE);
    print $POSTFORM;
    last;
  };
  #}}}
  #
  #{{{ GET /admission_rules/form : Html form for admission rules submission
  #
  $URI = qr{^/admission_rules/form.html$};
  OAR::API::GET( $_, $URI ) && do {
    (my $header, my $type)=OAR::API::set_output_format("html");
    print $header;
    print $HTML_HEADER;
    my $POSTFORM="";
    my $file = "/etc/oar/api_html_postform_rule.pl";
    open(FILE,$file);
    my(@lines) = <FILE>;
    eval join("\n",@lines);
    close(FILE);
    print $POSTFORM;
    last;
  };
  #}}}
  #
  #{{{ GET /resources/form : Html form for resources generation
  #
  $URI = qr{^/resources/form.html$};
  OAR::API::GET( $_, $URI ) && do {
    (my $header, my $type)=OAR::API::set_output_format("html");
    print $header;
    print $HTML_HEADER;
    my $POSTFORM="";
    my $file = "/etc/oar/api_html_postform_resources.pl";
    open(FILE,$file);
    my(@lines) = <FILE>;
    eval join("\n",@lines);
    close(FILE);
    print $POSTFORM;
    last;
  };
  #}}}
  #
  ###########################################
  # Anything else -> 404
  ###########################################
  #
  OAR::API::ERROR( 404, "Not found", "No way to handle your request " . $q->path_info );
}

} # End of fastcgi loop
