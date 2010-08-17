package SMT::NCCRegTools;
use strict;

use Log::Log4perl qw(get_logger :levels);
use LWP::UserAgent;
use URI;
use SMT::Parser::ListReg;
use SMT::Parser::ListSubscriptions;
use SMT::Parser::Bulkop;
use SMT::Utils;
use XML::Writer;
use Crypt::SSLeay;
use File::Temp;
use DBI qw(:sql_types);

use Data::Dumper;


# constructor
sub new
{
    my $pkgname = shift;
    my %opt   = @_;

    my $self  = {};

    $self->{URI}   = undef;
#    $self->{VBLEVEL} = 0;
    $self->{LOG}   = get_logger();
    $self->{OUT}   = get_logger('userlogger');
    
    $self->{USERAGENT}  = undef;

    $self->{MAX_REDIRECTS} = 5;

    $self->{AUTHUSER} = "";
    $self->{AUTHPASS} = "";

    $self->{HTTPSTATUS} = 0;

    if (! defined $opt{fromdir} ) {
        $self->{SMTGUID} = SMT::Utils::getSMTGuid();
    }

    $self->{NCCEMAIL} = "";

    $self->{DBH} = undef;

    $self->{TEMPDIR} = File::Temp::tempdir("smt-XXXXXXXX", CLEANUP => 1, TMPDIR => 1);

    $self->{FROMDIR} = undef;
    $self->{TODIR}   = undef;

    $self->{ERRORS} = 0;

    if(exists $opt{fromdir} && defined $opt{fromdir} && -d $opt{fromdir})
    {
        $self->{FROMDIR} = $opt{fromdir};
    }
    elsif(exists $opt{todir} && defined $opt{todir} && -d $opt{todir})
    {
        $self->{TODIR} = $opt{todir};
    }

    if(exists $opt{dbh} && defined $opt{dbh} && $opt{dbh})
    {
        $self->{DBH} = $opt{dbh};
    }
    elsif(!defined $self->{TODIR} || $self->{TODIR} eq "")
    {
        # init the database only if we do not sync to a directory
        $self->{DBH} = SMT::Utils::db_connect();
    }

    if(exists $opt{nccemail} && defined $opt{nccemail})
    {
        $self->{NCCEMAIL} = $opt{nccemail};
    }

    if(exists $opt{useragent} && defined $opt{useragent} && $opt{useragent})
    {
        $self->{USERAGENT} = $opt{useragent};
    }
    else
    {
        $self->{USERAGENT} = SMT::Utils::createUserAgent();
        $self->{USERAGENT}->protocols_allowed( [ 'https'] );
    }

    my ($ruri, $user, $pass) = SMT::Utils::getLocalRegInfos();

    $self->{URI}      = $ruri;
    $self->{AUTHUSER} = $user;
    $self->{AUTHPASS} = $pass;
    bless($self);

    return $self;
}

#
# return count of errors. 0 == success
#
sub NCCRegister
{
    my $self = shift;
    my $sleeptime = shift;

    my $errors = 0;

    if(! defined $self->{DBH} || !$self->{DBH})
    {
        $self->{LOG}->error("Database handle is not available.");
        $self->{OUT}->error(__("Database handle is not available."));
        return 1;
    }

    if(!defined $self->{NCCEMAIL} || $self->{NCCEMAIL} eq "")
    {
        $self->{LOG}->error("No email address for registration available.");
        $self->{OUT}->error(__("No email address for registration available."));
        return 1;
    }

    eval
    {
        # get all GUIDs which need a (re-)registration but not the once which failed before.
        my $allguids = $self->{DBH}->selectcol_arrayref("SELECT DISTINCT GUID from Registration WHERE (REGDATE > NCCREGDATE || NCCREGDATE IS NULL) && NCCREGERROR=0");

        if(@{$allguids} > 0)
        {
            # we have something to register, check for random sleep value
            sleep(int($sleeptime));

            $self->{LOG}->info(sprintf("Register %d new clients.", ($#{$allguids}+1)));
            $self->{OUT}->info(sprintf(__("Register %d new clients."), ($#{$allguids}+1)));
        }
        else
        {
            # nothing to register -- success
            return 0;
        }

        while(@$allguids > 0)
        {
            # register only 15 clients in one bulkop call
            my @guids = splice(@{$allguids}, 0, 15);

            my $output = "";

            my $writer;
            my $guidHash = {};

            $writer = new XML::Writer(OUTPUT => \$output);
            $writer->xmlDecl("UTF-8");

            my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
                     "client_version" => "1.2.3",
                     "lang" => "en");
            $writer->startTag("bulkop", %a);

            my $regtimestring = SMT::Utils::getDBTimestamp();
            foreach my $guid (@guids)
            {
                $regtimestring = SMT::Utils::getDBTimestamp();
                my $products = $self->{DBH}->selectall_arrayref(sprintf("select p.PRODUCTDATAID, p.PRODUCT, p.VERSION, p.REL, p.ARCH from Products p, Registration r where r.GUID=%s and r.PRODUCTID=p.PRODUCTDATAID", $self->{DBH}->quote($guid)), {Slice => {}});

                my $regdata =  $self->{DBH}->selectall_arrayref(sprintf("select KEYNAME, VALUE from MachineData where GUID=%s",
                                                                        $self->{DBH}->quote($guid)), {Slice => {}});

                $guidHash->{$guid} = $products;

                if(defined $regdata && ref($regdata) eq "ARRAY")
                {
                    $self->{LOG}->debug("Register '$guid'");

                    my $out = "";

                    $self->_buildRegisterXML($guid, $products, $regdata, $writer);
                }
                else
                {
                    $self->{LOG}->error(sprintf("Incomplete registration found. GUID:%s", $guid));
                    $self->{OUT}->error(sprintf(__("Incomplete registration found. GUID:%s"), $guid));
                    $errors++;
                    next;
                }
            }

            $writer->endTag("bulkop");

            if(!defined $output || $output eq "")
            {
                $self->{LOG}->error("Unable to generate XML");
                $self->{OUT}->error(__("Unable to generate XML"));
                $errors++;
                next;
            }
            my $destfile = $self->{TEMPDIR}."/bulkop.xml";

            my $ret= $self->_sendData($output, "command=bulkop", $destfile);
            if(! $ret)
            {
                $errors++;
                next;
            }

            $ret = $self->_updateRegistrationBulk($guidHash, $regtimestring, $destfile);
            if(!$ret)
            {
                $errors++;
                next;
            }
        }
    };
    if($@)
    {
        my $e = $@;
        $self->{LOG}->error($e);
        $self->{OUT}->error($e);
        $errors++;
    }
    return $errors;
}

#
# return count of errors. 0 == success
#
sub NCCListRegistrations
{
    my $self = shift;

    my $destfile = $self->{TEMPDIR};

    if(defined $self->{FROMDIR} && -d $self->{FROMDIR})
    {
        $destfile = $self->{FROMDIR}."/listregistrations.xml";
    }
    else
    {
        my $output = "";
        my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
                 "lang" => "en",
                 "client_version" => "1.2.3");

        my $writer = new XML::Writer(OUTPUT => \$output);
        $writer->xmlDecl("UTF-8");
        $writer->startTag("listregistrations", %a);

        $writer->startTag("authuser");
        $writer->characters($self->{AUTHUSER});
        $writer->endTag("authuser");

        $writer->startTag("authpass");
        $writer->characters($self->{AUTHPASS});
        $writer->endTag("authpass");

        $writer->startTag("smtguid");
        $writer->characters($self->{SMTGUID});
        $writer->endTag("smtguid");

        $writer->endTag("listregistrations");

        if(defined $self->{TODIR} && $self->{TODIR} ne "")
        {
            $destfile = $self->{TODIR};
        }

        $destfile .= "/listregistrations.xml";
        my $ok = $self->_sendData($output, "command=listregistrations", $destfile);

        if(!$ok || !-e $destfile)
        {
            if($self->{HTTPSTATUS} == 501)
            {
                $self->{LOG}->warn("List registrations not implemented.");
                $self->{OUT}->warn(__("List registrations not implemented."));
                return 0;
            }
            else
            {
                $self->{LOG}->error("List registrations request failed.");
                $self->{OUT}->error(__("List registrations request failed."));
                return 1;
            }
        }
    }

    if(defined $self->{TODIR} && $self->{TODIR} ne "")
    {
        return 0;
    }
    else
    {
        if(! defined $self->{DBH} || !$self->{DBH})
        {
            $self->{LOG}->error("Database handle is not available.");
            $self->{OUT}->error(__("Database handle is not available."));
            return 1;
        }

        if(! defined $destfile || ! -e $destfile)
        {
            $self->{LOG}->error(sprintf("File '%s' does not exist.", $destfile));
            $self->{OUT}->error(sprintf(__("File '%s' does not exist."), $destfile));
            return 1;
        }

        my $sth = $self->{DBH}->prepare("SELECT DISTINCT GUID from Registration WHERE NCCREGDATE IS NOT NULL");
        #$sth->bind_param(1, '1970-01-02 00:00:01', SQL_TIMESTAMP);
        $sth->execute;
        my $guidhash = $sth->fetchall_hashref("GUID");

        # The _listreg_handler fill the ClientSubscription table new.
        # Here we need to delete it first

        $self->{DBH}->do("DELETE from ClientSubscriptions");

        my $parser = new SMT::Parser::ListReg(); #log => $self->{LOG});
        my $err = $parser->parse($destfile, sub{ _listreg_handler($self, $guidhash, @_)});
        if($err)
        {
            return $err;
        }

        # $guidhash includes now a list of GUIDs which are no longer in NCC
        # A customer may have removed them via NCC web page.
        # So remove them also here in SMT

        $self->_deleteRegistrationLocal(keys %{$guidhash});

        return 0;
    }
}

#
# return count of errors. 0 == success
#
sub NCCListSubscriptions
{
    my $self = shift;

    my $destfile = $self->{TEMPDIR};

    if(defined $self->{FROMDIR} && -d $self->{FROMDIR})
    {
        $destfile = $self->{FROMDIR}."/listsubscriptions.xml";
    }
    else
    {
        my $output = "";
        my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
                 "lang" => "en",
                 "client_version" => "1.2.3");

        my $writer = new XML::Writer(OUTPUT => \$output);
        $writer->xmlDecl("UTF-8");
        $writer->startTag("listsubscriptions", %a);

        $writer->startTag("authuser");
        $writer->characters($self->{AUTHUSER});
        $writer->endTag("authuser");

        $writer->startTag("authpass");
        $writer->characters($self->{AUTHPASS});
        $writer->endTag("authpass");

        $writer->startTag("smtguid");
        $writer->characters($self->{SMTGUID});
        $writer->endTag("smtguid");

        $writer->endTag("listsubscriptions");

        if(defined $self->{TODIR} && $self->{TODIR} ne "")
        {
            $destfile = $self->{TODIR};
        }

        $destfile .= "/listsubscriptions.xml";
        my $ok = $self->_sendData($output, "command=listsubscriptions", $destfile);

        if(!$ok || !-e $destfile)
        {
            if($self->{HTTPSTATUS} == 501)
            {
                $self->{LOG}->warn("List subscriptions not implemented.");
                $self->{OUT}->warn(__("List subscriptions not implemented."));
                return 0;
            }
            else
            {
                $self->{LOG}->error("List subscriptions request failed.");
                $self->{OUT}->error(__("List subscriptions request failed."));
                return 1;
            }
        }
    }

    if(defined $self->{TODIR} && $self->{TODIR} ne "")
    {
        return 0;
    }
    else
    {
        if(! defined $self->{DBH} || !$self->{DBH})
        {
            $self->{LOG}->error("Database handle is not available.");
            $self->{OUT}->error(__("Database handle is not available."));
            return 1;
        }

        if(! defined $destfile || ! -e $destfile)
        {
            $self->{LOG}->error(sprintf("File '%s' does not exist.", $destfile));
            $self->{OUT}->error(sprintf(__("File '%s' does not exist."), $destfile));
            return 1;
        }

        # The _listsub_handler fill the Subscriptions table new.
        # Here we need to delete it first

        $self->{DBH}->do("DELETE from Subscriptions");

        my $parser = new SMT::Parser::ListSubscriptions(log => $self->{LOG});
        my $err = $parser->parse($destfile, sub{ _listsub_handler($self, @_)});
        return $err if($err);

        return 0;
    }
}


#
# return count of errors. 0 == success
#
sub NCCDeleteRegistration
{
    my $self = shift;
    my $guidhash = {};
    foreach (@_)
    {
        $guidhash->{$_} = [];
    }

    my $errors = 0;
    my $found = 0;

    if(! defined $self->{DBH} || !$self->{DBH})
    {
        $self->{LOG}->error("Database handle is not available.");
        $self->{OUT}->error(__("Database handle is not available."));
        return 1;
    }

    # check if we are allowed to register clients at NCC
    # if no, we are also not allowed to remove them

    my $cfg = undef;

    eval
    {
        $cfg = SMT::Utils::getSMTConfig();
    };
    if($@ || !defined $cfg)
    {
        my $e = $@;
        $self->{LOG}->error(sprintf("Cannot read the SMT configuration file: %s", $e));
        $self->{OUT}->error(sprintf(__("Cannot read the SMT configuration file: %s"), $e));
        return 1;
    }

    my $allowRegister = $cfg->val("LOCAL", "forwardRegistration");

    my $output = "";
    my %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
             "lang" => "en",
             "client_version" => "1.2.3");

    my $writer = new XML::Writer(OUTPUT => \$output);
    $writer->xmlDecl("UTF-8");
    $writer->startTag("bulkop", %a);

    foreach my $guid (keys %{$guidhash})
    {
        # check if this client was registered at NCC
        # we have to execute this before calling _deleteRegistrationLocal
        my $sth = $self->{DBH}->prepare("SELECT GUID from Registration where NCCREGDATE IS NOT NULL and GUID=?");
        $sth->bind_param(1, $guid);
        $sth->execute;

        my $result = $sth->fetchrow_arrayref();
        $self->{LOG}->debug("Statement: ".$sth->{Statement});

        my $s = sprintf("SELECT KEYNAME, VALUE from MachineData where GUID=%s",
                        $self->{DBH}->quote($guid));

        my $ost = $self->{DBH}->selectall_arrayref($s, {Slice=>{}});
        $self->{LOG}->debug("Statement: $s") ;

        my $ostarget = "";
        my $ostargetbak = "";
        foreach my $x (@$ost)
        {
            if($x->{KEYNAME} eq "ostarget")
            {
                $ostarget = $x->{VALUE};
            }
            elsif($x->{KEYNAME} eq "ostarget-bak")
            {
                $ostargetbak = $x->{VALUE};
            }
        }

        $self->_deleteRegistrationLocal($guid);

        if(!(exists $result->[0] && defined $result->[0] && $result->[0] eq $guid))
        {
            # this GUID was never registered at NCC
            # no need to delete it there
            next;
        }

        if(!(defined $allowRegister && $allowRegister eq "true"))
        {
            $self->{LOG}->warn(sprintf("Forward registration is disabled. '%s' deleted only locally. ", $guid));
            $self->{OUT}->warn(sprintf(__("Forward registration is disabled. '%s' deleted only locally. "), $guid));
            next;
        }

        $found++;

        $writer->startTag("de-register");

        $writer->startTag("guid");
        $writer->characters($guid);
        $writer->endTag("guid");

        $writer->startTag("authuser");
        $writer->characters($self->{AUTHUSER});
        $writer->endTag("authuser");

        $writer->startTag("authpass");
        $writer->characters($self->{AUTHPASS});
        $writer->endTag("authpass");

        $writer->startTag("smtguid");
        $writer->characters($self->{SMTGUID});
        $writer->endTag("smtguid");

        if($ostarget ne "")
        {
            $writer->startTag("param", id => "ostarget");
            $writer->cdata($ostarget);
            $writer->endTag("param");
        }
        if($ostargetbak ne "")
        {
            $writer->startTag("param", id => "ostarget-bak");
            $writer->cdata($ostargetbak);
            $writer->endTag("param");
        }

        $writer->endTag("de-register");

    }
    $writer->endTag("bulkop");

    if($found == 0)
    {
        # nothing todo - success
        return 0;
    }

    if(!defined $output || $output eq "")
    {
        $self->{LOG}->error("Unable to generate XML");
        $self->{OUT}->error(__("Unable to generate XML"));
        $errors++;
        return $errors;
    }
    my $destfile = $self->{TEMPDIR}."/bulkop.xml";

    my $ok = $self->_sendData($output, "command=bulkop", $destfile);

    if(!$ok)
    {
        $errors++;
        return $errors;
    }

    $ok = $self->_updateRegistrationBulk($guidhash, "", $destfile);
    if(!$ok)
    {
        $errors++;
        return $errors;
    }

    return $errors;
}


###############################################################################
###############################################################################
###############################################################################
###############################################################################

sub _deleteRegistrationLocal
{
    my $self = shift;
    my @guids = @_;

    my $where = "";
    if(@guids == 0)
    {
        return 1;
    }

    foreach my $guid (@guids)
    {
        my $found = 0;

        $where = sprintf("GUID = %s", $self->{DBH}->quote( $guid ) );

        my $statement = "DELETE FROM Registration where ".$where;

        my $res = $self->{DBH}->do($statement);

        $self->{LOG}->debug("Statement: $statement Result: $res") ;

        $found = 1 if( $res > 0 );

        $statement = "DELETE FROM Clients where ".$where;

        $res = $self->{DBH}->do($statement);

        $self->{LOG}->debug("Statement: $statement Result: $res") ;

        $statement = "DELETE FROM MachineData where ".$where;

        $res = $self->{DBH}->do($statement);

        $self->{LOG}->debug("Statement: $statement Result: $res") ;

        #FIXME: does it make sense to remove this GUID from ClientSubscriptions ?

        if($found)
        {
            $self->{LOG}->info(sprintf("Successfully delete registration locally : %s", $guid));
            $self->{OUT}->info(sprintf(__("Successfully delete registration locally : %s"), $guid));
        }
        else
        {
            $self->{LOG}->info(sprintf("Delete registration locally failed: %s", $guid));
            $self->{OUT}->info(sprintf(__("Delete registration locally failed: %s"), $guid));
        }
    }

    return 1;
}


sub _listreg_handler
{
    my $self     = shift;
    my $guidhash = shift;
    my $data     = shift;

    my $statement = "";

    if(!exists $data->{GUID} || !defined $data->{GUID})
    {
        # should not happen, but it is better to check it
        return;
    }

    eval
    {
        # check if data->{GUID} exists localy
        if(exists $guidhash->{$data->{GUID}})
        {
            delete $guidhash->{$data->{GUID}};

            foreach my $subid (@{$data->{SUBREF}})
            {
                $statement = sprintf("INSERT INTO ClientSubscriptions (GUID, SUBID) VALUES(%s, %s)",
                                     $self->{DBH}->quote($data->{GUID}),
                                     $self->{DBH}->quote($subid));

                $self->{DBH}->do($statement);
                $self->{LOG}->debug("$statement") ;
            }
        }
        else
        {
            # FIXME: maybe we get GUID from other SMTs of this company. If yes, we should
            #        skip this warning.
            #
            # We found a registration from SMT in NCC which does not exist in SMT anymore
            # print and error. The admin has to delete it in NCC by hand.
            $self->{LOG}->warn(sprintf("WARNING: Found a Client in NCC which is not available here: '%s'", $data->{GUID}));
            $self->{OUT}->warn(sprintf(__("WARNING: Found a Client in NCC which is not available here: '%s'"), $data->{GUID}));
        }
    };
    if($@)
    {
        my $e = $@;
        $self->{LOG}->error($e);
        $self->{OUT}->error($e);
        return;
    }
    return;
}

sub _bulkop_handler
{
    my $self          = shift;
    my $guidHash      = shift;
    my $regtimestring = shift;
    my $data          = shift;
    my $operation     = "";

    $regtimestring = SMT::Utils::getDBTimestamp() if(!defined $regtimestring || $regtimestring eq "");

    if(!exists $data->{GUID} || ! defined $data->{GUID} || $data->{GUID} eq "")
    {
        # something goes wrong
        $self->{LOG}->error("No GUID");
        $self->{OUT}->error(__("No GUID"));
        $self->{ERRORS} += 1;
        return;
    }
    my $guid = $data->{GUID};


    if(!exists $data->{OPERATION} || !defined $data->{OPERATION} ||
       !($data->{OPERATION} eq "register" || $data->{OPERATION} eq "de-register"))
    {
        # this should not happen
        $self->{LOG}->error(sprintf("Unknown bulk operation '%s'.", $data->{OPERATION}));
        $self->{OUT}->error(sprintf(__("Unknown bulk operation '%s'."), $data->{OPERATION}));
        $self->{ERRORS} += 1;
    }
    $operation = $data->{OPERATION};

    # evaluate the status

    if(! exists $data->{RESULT} || ! defined $data->{RESULT} || $data->{RESULT} eq "")
    {
        # something goes wrong
        $self->{LOG}->error("No RESULT");
        $self->{OUT}->error(__("No RESULT"));
        $self->{ERRORS} += 1;
        return;
    }

    if($data->{RESULT} eq "error")
    {
        $self->{LOG}->error(sprintf("Operation %s[%s] failed: %s", $operation, $guid, $data->{MESSAGE}));
        $self->{OUT}->error(sprintf(__("Operation %s[%s] failed: %s"), $operation, $guid, $data->{MESSAGE}));
        $self->{ERRORS} += 1;
        if($operation ne "register")
        {
            # on registration we have to update the registration table even on error.
            return;
        }
    }
    elsif($data->{RESULT} eq "warning")
    {
        $self->{LOG}->warn(sprintf("Operation: %s[%s] : %s", $operation, $guid, $data->{MESSAGE}));
        $self->{OUT}->warn(sprintf(__("Operation: %s[%s] : %s"), $operation, $guid, $data->{MESSAGE}));
    }
    # else success

    if(!exists $guidHash->{$guid} || ! defined $guidHash->{$guid} || ref($guidHash->{$guid}) ne "ARRAY")
    {
        # something goes wrong
        return;
    }

    if(exists $data->{OPERATION} && defined $data->{OPERATION} && $data->{OPERATION} eq "register")
    {
        my @q_productids = ();
        foreach my $prod (@{$guidHash->{$guid}})
        {
            if( exists $prod->{PRODUCTDATAID} && defined $prod->{PRODUCTDATAID} )
            {
                push @q_productids, $self->{DBH}->quote($prod->{PRODUCTDATAID});
            }
        }

        my $statement = "";
        if($data->{RESULT} ne "error")
        {
            $statement = "UPDATE Registration SET NCCREGDATE=?, NCCREGERROR=0 WHERE GUID=%s and ";
            if(@q_productids > 1)
            {
                $statement .= "PRODUCTID IN (".join(",", @q_productids).")";
            }
            elsif(@q_productids == 1)
            {
                $statement .= "PRODUCTID = ".$q_productids[0];
            }
            else
            {
                # this should not happen
                $self->{LOG}->error("No products found.");
                $self->{OUT}->error(__("No products found."));
                $self->{ERRORS} += 1;
                return;
            }
            my $sth = $self->{DBH}->prepare(sprintf("$statement", $self->{DBH}->quote($guid)));
            $sth->bind_param(1, $regtimestring, SQL_TIMESTAMP);
            $sth->execute;
            $self->{LOG}->info(sprintf("Registration success: '%s'.", $guid));
            $self->{OUT}->info(sprintf(__("Registration success: '%s'."), $guid));
        }
        else  # error
        {
            # on error we set NCCREGERROR to 1
            $statement = "UPDATE Registration SET NCCREGERROR=1 WHERE GUID=%s and ";
            if(@q_productids > 1)
            {
                $statement .= "PRODUCTID IN (".join(",", @q_productids).")";
            }
            elsif(@q_productids == 1)
            {
                $statement .= "PRODUCTID = ".$q_productids[0];
            }
            else
            {
                # this should not happen
                $self->{LOG}->error("No products found.");
                $self->{OUT}->error(__("No products found."));
                $self->{ERRORS} += 1;
                return;
            }
            my $res = $self->{DBH}->do(sprintf("$statement", $self->{DBH}->quote($guid)));
            $self->{LOG}->debug(sprintf("$statement", $self->{DBH}->quote($guid))) ;
        }
    }
    elsif(exists $data->{OPERATION} && defined $data->{OPERATION} && $data->{OPERATION} eq "de-register")
    {
        $self->{LOG}->info(sprintf("Successfully delete registration on registration server: '%s'", $guid));
        $self->{OUT}->info(sprintf(__("Successfully delete registration on registration server: '%s'"), $guid));
    }
}


sub _listsub_handler
{
    my $self     = shift;
    my $data     = shift;

    my $statement = "";

    # FIXME: require CONSUMED?
    if(!exists $data->{SUBID} || !defined $data->{SUBID} || $data->{SUBID} eq "" ||
       !exists $data->{NAME} || !defined $data->{NAME} || $data->{NAME} eq "" ||
       !exists $data->{STATUS} || !defined $data->{STATUS} || $data->{STATUS} eq "" ||
       !exists $data->{ENDDATE} || !defined $data->{ENDDATE} || $data->{ENDDATE} eq "" ||
       !exists $data->{PRODUCTCLASS} || !defined $data->{PRODUCTCLASS} || $data->{PRODUCTCLASS} eq "" ||
       !exists $data->{NODECOUNT} || !defined $data->{NODECOUNT} || $data->{NODECOUNT} eq "")
    {
        # should not happen, but it is better to check it
        $self->{LOG}->error("ListSubscriptions: incomplete data set. Skip");
        $self->{OUT}->error(__("ListSubscriptions: incomplete data set. Skip"));
        $self->{LOG}->debug("ListSubscriptions: incomplete data set: ".Data::Dumper->Dump([$data]));
        return;
    }

    eval
    {
        $statement  = "INSERT INTO Subscriptions(SUBID, REGCODE, SUBNAME, SUBTYPE, SUBSTATUS, SUBSTARTDATE, SUBENDDATE, ";
        $statement .= "SUBDURATION, SERVERCLASS, PRODUCT_CLASS, NODECOUNT, CONSUMED, CONSUMEDVIRT)";
        # bind_param with SQL_INTEGER seems not to support negative integers. So we need to workaround NODECOUNT
        $statement .= sprintf(" VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, %s, ?, ?)", $self->{DBH}->quote(int($data->{NODECOUNT})));

        my $sth = $self->{DBH}->prepare($statement);
        $sth->bind_param(1, $data->{SUBID});
        $sth->bind_param(2, $data->{REGCODE});
        $sth->bind_param(3, $data->{NAME});
        $sth->bind_param(4, $data->{TYPE});
        $sth->bind_param(5, $data->{STATUS});
        if(int($data->{STARTDATE}) == 0)
        {
            $sth->bind_param(6, undef, SQL_TIMESTAMP);
        }
        else
        {
            $sth->bind_param(6, SMT::Utils::getDBTimestamp($data->{STARTDATE}), SQL_TIMESTAMP);
        }

        if(int($data->{ENDDATE}) == 0)
        {
            $sth->bind_param(7, undef, SQL_TIMESTAMP);
        }
        else
        {
            $sth->bind_param(7, SMT::Utils::getDBTimestamp($data->{ENDDATE}), SQL_TIMESTAMP);
        }

        $sth->bind_param(8, $data->{DURATION}, SQL_INTEGER);
        $sth->bind_param(9, $data->{SERVERCLASS});

        $sth->bind_param(10, $data->{PRODUCTCLASS});

        $sth->bind_param(11, int($data->{CONSUMED}), SQL_INTEGER);
        $sth->bind_param(12, int($data->{CONSUMEDVIRT}), SQL_INTEGER);

        my $res = $sth->execute;

        $self->{LOG}->debug($sth->{Statement}." :$res") ;
    };
    if($@)
    {
        my $e = $@;
        $self->{LOG}->error($e);
        $self->{OUT}->error($e);
        return;
    }
    return;
}

sub _updateRegistrationBulk
{
    my $self          = shift || undef;
    my $guidHash      = shift || undef;
    my $regtimestring = shift || undef;
    my $respfile      = shift || undef;

    $regtimestring = SMT::Utils::getDBTimestamp() if(!defined $regtimestring || $regtimestring eq "");

    if(!defined $guidHash)
    {
        $self->{LOG}->error("Invalid GUIDHASH parameter");
        $self->{OUT}->error(__("Invalid GUIDHASH parameter"));
        return 0;
    }

    if(!defined $regtimestring)
    {
        $self->{LOG}->error("Invalid time string");
        $self->{OUT}->error(__("Invalid time string"));
        return 0;
    }

    if(! defined $respfile || ! -e $respfile)
    {
        $self->{LOG}->error("Invalid server response");
        $self->{OUT}->error(__("Invalid server response"));
        return 0;
    }


    # A parser for the answer is required here and everything below this comment
    # should be part of the handler

    $self->{ERRORS} = 0;

    my $parser = new SMT::Parser::Bulkop();
    my $err = $parser->parse($respfile, sub{ _bulkop_handler($self, $guidHash, $regtimestring, @_)});
    $self->{ERRORS} += $err;

    if( $self->{ERRORS} > 0 )
    {
        return 0;
    }
    return 1;
}


sub _sendData
{
    my $self = shift || undef;
    my $data = shift || undef;
    my $query = shift || undef;
    my $destfile = shift || undef;

    my $defaultquery = "lang=en-US&version=1.0";

    if (! defined $self->{URI})
    {
        $self->{LOG}->error("Cannot send data to registration server. Missing URL.");
        $self->{OUT}->error(__("Cannot send data to registration server. Missing URL."));
        return 0;
    }
    if($self->{URI} =~ /^-/)
    {
        $self->{LOG}->error(sprintf("Invalid protocol(%s).", $self->{URI}));
        $self->{OUT}->error(sprintf(__("Invalid protocol(%s)."), $self->{URI}));
        return 0;
    }

    my $regurl = URI->new($self->{URI});
    if(defined $query && $query =~ /\w=\w/)
    {
        $regurl->query($query."&".$defaultquery);
    }
    else
    {
        $regurl->query($defaultquery);
    }

    my %params = ('Content' => $data);
    if(defined $destfile && $destfile ne "")
    {
        $params{':content_file'} = $destfile;
    }

    my $response = "";
    my $redirects = 0;

    do
    {
        $self->{LOG}->debug("SEND TO: ".$regurl->as_string()) ;
        $self->{LOG}->debug("XML:\n$data") ;

        eval
        {
            $response = $self->{USERAGENT}->post( $regurl->as_string(), 'Content-Type' => 'text/xml', %params);
        };
        if($@)
        {
          my $e = $@;
          $self->{LOG}->error(sprintf(__("Failed to download '%s'"),$regurl->as_string()));
          $self->{OUT}->error(sprintf(__("Failed to download '%s'"),$regurl->as_string()));
          $self->{LOG}->error($e);
          $self->{OUT}->error($e);
          return 0;
        }

        $self->{LOG}->debug("Result: ".$response->code()." ".$response->message()) ;

        if ( $response->is_redirect )
        {
            $redirects++;
            if($redirects > $self->{MAX_REDIRECTS})
            {
                $self->{LOG}->error("Reach maximal redirects. Abort");
                $self->{OUT}->error(__("Reach maximal redirects. Abort"));
                return undef;
            }

            my $newuri = $response->header("location");

            $self->{LOG}->debug("Redirected to $newuri") ;
            $regurl = URI->new($newuri);
        }
    } while($response->is_redirect);

    $self->{HTTPSTATUS} = $response->code();

    if($response->is_success && -e $destfile)
    {
        if($self->{LOG}->is_trace())
        {
            open(CONT, "< $destfile") and do
            {
                my @c = <CONT>;
                close CONT;
                $self->{LOG}->debug("Content:".join("\n", @c));
            };
        }
        return 1;
    }
    elsif($response->is_error && $response->code() == 501)
    {
        $self->{LOG}->debug("Not implemented.");
        return 0;
    }
    else
    {
        $self->{LOG}->error(sprintf("Invalid response: %s", $response->status_line));
        $self->{OUT}->error(sprintf(__("Invalid response: %s"), $response->status_line));
        return 0;
    }
}


sub _buildRegisterXML
{
    my $self     = shift;
    my $guid     = shift;
    my $products = shift;
    my $regdata  = shift;
    my $writer   = shift;

    my $output = "";
    my %a = ();
    if(! defined $writer || !$writer)
    {
        $writer = new XML::Writer(OUTPUT => \$output);
        $writer->xmlDecl("UTF-8");

        %a = ("xmlns" => "http://www.novell.com/xml/center/regsvc-1_0",
              "lang" => "en",
              "client_version" => "1.2.3");
    }

    $a{force} = "batch";

    $writer->startTag("register", %a);

    $writer->startTag("guid");
    $writer->characters($guid);
    $writer->endTag("guid");

    my $host = "";
    my $virtType = "";

    foreach my $pair (@{$regdata})
    {
        if($pair->{KEYNAME} eq "host" && defined $pair->{VALUE} && $pair->{VALUE} ne "")
        {
            $host = $pair->{VALUE};
        }
        if($pair->{KEYNAME} eq "virttype" && defined $pair->{VALUE} && $pair->{VALUE} ne "")
        {
            $virtType = $pair->{VALUE};
        }
    }

    if(defined $host && $host ne "")
    {
        if(defined $virtType && $virtType ne "")
        {
            $writer->startTag("host", type => $virtType );
            $writer->characters($host);
            $writer->endTag("host");
        }
        else
        {
            $writer->startTag("host");
            $writer->characters($host);
            $writer->endTag("host");
        }
    }
    elsif(defined $virtType && $virtType ne "")
    {
        $writer->emptyTag("host", type => $virtType );
    }
    else
    {
        $writer->emptyTag("host");
    }

    $writer->startTag("authuser");
    $writer->characters($self->{AUTHUSER});
    $writer->endTag("authuser");

    $writer->startTag("authpass");
    $writer->characters($self->{AUTHPASS});
    $writer->endTag("authpass");

    $writer->startTag("smtguid");
    $writer->characters($self->{SMTGUID});
    $writer->endTag("smtguid");

    foreach my $PHash (@{$products})
    {
        if(!exists $PHash->{PRODUCTDATAID} || ! defined $PHash->{PRODUCTDATAID} ||
           $PHash->{PRODUCTDATAID} eq "")
        {
            next;
        }

        foreach my $pair (@{$regdata})
        {
            if($pair->{KEYNAME} eq "product-name-".$PHash->{PRODUCTDATAID} &&
               defined $pair->{VALUE} && $pair->{VALUE} ne "")
            {
                $PHash->{PRODUCT} = $pair->{VALUE};
            }
            elsif($pair->{KEYNAME} eq "product-version-".$PHash->{PRODUCTDATAID} &&
                  defined $pair->{VALUE} && $pair->{VALUE} ne "")
            {
                $PHash->{VERSION} = $pair->{VALUE};
            }
            elsif($pair->{KEYNAME} eq "product-arch-".$PHash->{PRODUCTDATAID} &&
                  defined $pair->{VALUE} && $pair->{VALUE} ne "")
            {
                $PHash->{ARCH} = $pair->{VALUE};
            }
            elsif($pair->{KEYNAME} eq "product-rel-".$PHash->{PRODUCTDATAID} &&
                  defined $pair->{VALUE} && $pair->{VALUE} ne "")
            {
                $PHash->{REL} = $pair->{VALUE};
            }
        }

        if(defined $PHash->{PRODUCT} && $PHash->{PRODUCT} ne "" &&
           defined $PHash->{VERSION} && $PHash->{VERSION} ne "")
        {
            $writer->startTag("product",
                              "version" => $PHash->{VERSION},
                              "release" => (defined $PHash->{REL})?$PHash->{REL}:"",
                              "arch"    => (defined $PHash->{ARCH})?$PHash->{ARCH}:"");
            if ($PHash->{PRODUCT} =~ /\s+/)
            {
                $writer->cdata($PHash->{PRODUCT});
            }
            else
            {
                $writer->characters($PHash->{PRODUCT});
            }
            $writer->endTag("product");
        }
    }

    my $foundEmail = 0;

    foreach my $pair (@{$regdata})
    {
        next if($pair->{KEYNAME} eq "host" || $pair->{KEYNAME} eq "virttype");
        next if($pair->{KEYNAME} =~ /^product-/);

        if(!defined $pair->{VALUE})
        {
            $pair->{VALUE} = "";
        }

        if($pair->{KEYNAME} eq "email" )
        {
            if($pair->{VALUE} ne "")
            {
                $foundEmail = 1;
            }
            else
            {
                $foundEmail = 1;
                $pair->{VALUE} = $self->{NCCEMAIL};
            }
        }

        if($pair->{VALUE} eq "")
        {
            $writer->emptyTag("param", "id" => $pair->{KEYNAME});
        }
        else
        {
            $writer->startTag("param",
                              "id" => $pair->{KEYNAME});
            if ($pair->{VALUE} =~ /\s+/)
            {
                $writer->cdata($pair->{VALUE});
            }
            else
            {
                $writer->characters($pair->{VALUE});
            }
            $writer->endTag("param");
        }
    }

    if(!$foundEmail)
    {
        $writer->startTag("param",
                          "id" => "email");
        $writer->characters($self->{NCCEMAIL});
        $writer->endTag("param");
    }

    $writer->endTag("register");

    return $output;
}

1;
