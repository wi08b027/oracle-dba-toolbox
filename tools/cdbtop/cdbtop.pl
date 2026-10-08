#!/usr/bin/env perl
#
# cdbtop.pl - "top" for many Oracle instances on one Linux host (CDB / PDB aware)
#
#   Instances  ->  Containers (CDB$ROOT / PDBs)  ->  Processes  ->  Session detail
#                                                                   (SQL text, PL/SQL, plan, waits)
#
#   * run as the Oracle software owner (uses "/ as sysdba" OS authentication)
#   * core Perl only (works with the perl in $ORACLE_HOME/perl too) + sqlplus of each home
#   * Oracle 12.1+ ; uses no Diagnostics/Tuning Pack views (no ASH, AWR, SQL Monitor)
#
#   usage:  ./cdbtop.pl [-d secs] [-s SID1,SID2] [-t timeout] [-c "/ as sysdba"] [-b [-n N]]
#
use strict;
use warnings;
use POSIX ();
use IO::Select;
use IO::Handle;
use File::Temp qw(tempdir);
use Getopt::Long qw(:config no_ignore_case bundling);
use Time::HiRes qw(time sleep);

my $VERSION = '1.0';

# ------------------------------------------------------------------ options
my %opt = (delay => 5, timeout => 15, connect => '/ as sysdba', iter => 1);
GetOptions(
    'd|delay=f'      => \$opt{delay},
    't|timeout=i'    => \$opt{timeout},
    's|sid=s'        => \$opt{sids},
    'c|connect=s'    => \$opt{connect},
    'b|batch'        => \$opt{batch},
    'n|iterations=i' => \$opt{iter},
    'h|help'         => \$opt{help},
) or usage(1);
usage(0) if $opt{help};
$opt{delay} = 1 if $opt{delay} < 1;
my %only = map { $_ => 1 } grep { length } split /,/, ($opt{sids} // '');

sub usage {
    print <<"EOT";
cdbtop $VERSION - top-like monitor for Oracle instances (CDB/PDB aware)

usage: $0 [options]
  -d, --delay SECS       refresh interval (default 5)
  -s, --sid SID[,SID]    only these instances (default: all running ora_pmon_*)
  -t, --timeout SECS     max time to wait for one instance's sqlplus (default 15)
  -c, --connect STR      sqlplus connect string (default "/ as sysdba")
  -b, --batch            non-interactive: print snapshot(s) to stdout
  -n, --iterations N     number of snapshots in batch mode (default 1)
  -h, --help             this help

Interactive keys: press ? inside the tool.
EOT
    exit($_[0] // 0);
}

# ------------------------------------------------------------------ globals
my $CLK  = POSIX::sysconf(POSIX::_SC_CLK_TCK()) || 100;
my $PAGE = (eval { POSIX::sysconf(POSIX::_SC_PAGESIZE()) }) || 4096;
my $TMP  = tempdir('cdbtop.XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $INST_SQL   = "$TMP/inst.sql";
my $DETAIL_SQL = "$TMP/detail.sql";
write_file($INST_SQL, inst_sql());

my (%inst, %prevproc, %prevdb, %host, $prev_hcpu, $last_os_t);
my ($W, $H) = (200, 50);
my $mode  = 'inst';            # inst | pdb | proc | detail | help
my @stack;                     # previous modes
my %ctx;                       # sid (instance), con (container filter or undef)
my %selk;                      # selected row key per mode
my %lastidx;                   # last selected index per mode
my %off;                       # scroll offset per mode
my %sortk = (inst => 'c', pdb => 'c', proc => 'c');
my ($cur_keys, $cur_idx, $page_rows) = ([], 0, 10);
my $only_active = 0;
my $wrap        = 1;
my $detail;                    # session detail state
my ($msg, $msg_t) = ('', 0);
my ($winch, $force) = (0, 0);
my $TTY_SAVE;
my $MAIN_PID = $$;

my %STY = ('' => '', h => "\e[1m", r => "\e[7m", s => "\e[1;37;44m",
           w => "\e[31m", a => "\e[32m", b => "\e[1;36m");

my %SORTNAME = (c => 'CPU', m => 'memory', a => 'active/AAS', o => 'I/O', e => 'elapsed', n => 'name');

# ------------------------------------------------------------------ SQL
sub inst_sql {
    return <<'SQL';
whenever sqlerror continue
set pagesize 0 linesize 32767 trimspool on trimout on feedback off heading off verify off echo off timing off tab off define off
alter session set nls_numeric_characters = '.,';
select 'I|'||instance_name||'|'||version||'|'||status||'|'||to_char(startup_time,'YYYYMMDDHH24MISS') from v$instance;
select 'V|'||version_full from v$instance;
select 'B|'||cdb||'|'||open_mode||'|'||database_role from v$database;
select 'G|'||round(sum(value)/1048576) from v$sga;
select 'P|'||round(value/1048576) from v$pgastat where name = 'total PGA allocated';
select 'Y|'||stat_name||'|'||value from v$sys_time_model where stat_name in ('DB time','DB CPU');
select 'Z|'||name||'|'||value from v$sysstat
 where name in ('session logical reads','physical read total bytes','physical write total bytes','execute count');
select 'D|'||con_id||'|'||name||'|'||open_mode||'|'||round(nvl(total_size,0)/1048576) from v$containers;
select 'T|'||con_id||'|'||stat_name||'|'||value from v$con_sys_time_model where stat_name in ('DB time','DB CPU');
select 'S|'||p.spid||'|'||s.sid||'|'||s.serial#||'|'||s.con_id||'|'||nvl(s.username,'-')||'|'||s.status||'|'||
       nvl(s.sql_id,'-')||'|'||replace(nvl(s.event,'-'),'|','/')||'|'||
       replace(substr(nvl(s.module,nvl(s.program,'-')),1,48),'|','/')||'|'||s.type||'|'||
       round(p.pga_alloc_mem/1048576,1)||'|'||s.last_call_et||'|'||nvl(s.wait_class,'-')||'|'||
       nvl(to_char(s.blocking_session),'-')||'|'||s.state||'|'||
       decode(s.sid, to_number(sys_context('USERENV','SID')), 'Y', 'N')
  from v$session s, v$process p
 where s.paddr = p.addr;
exit
SQL
}

sub detail_sql {
    my ($ssid, $serial, $conname) = @_;
    my $sql = <<'SQL';
whenever sqlerror continue
set pagesize 0 linesize 32767 trimspool on trimout on feedback off heading off verify off echo off timing off tab off
set long 1000000 longchunksize 32767 define on
alter session set nls_numeric_characters = '.,';
__SWITCH__
define v_sqlid = ''
define v_chld  = 0
define v_what  = 'n/a'
set termout off
column c_sqlid new_value v_sqlid
column c_chld  new_value v_chld
column c_what  new_value v_what
select nvl(sql_id, prev_sql_id) c_sqlid,
       nvl(decode(sql_id, null, prev_child_number, sql_child_number), 0) c_chld,
       decode(sql_id, null, 'LAST EXECUTED - session has no active statement', 'CURRENTLY EXECUTING') c_what
  from v$session where __W__;
set termout on
select '*** session no longer exists ***' from dual where not exists (select 1 from v$session where __W__);
prompt ===== SESSION
select 'SID,SERIAL#  : '||s.sid||','||s.serial#||'    OS PID: '||p.spid||'    Container: '||sys_context('USERENV','CON_NAME')||chr(10)||
       'User         : '||nvl(s.username,'('||s.type||')')||'    Schema: '||s.schemaname||'    OS user: '||s.osuser||chr(10)||
       'Client       : '||s.machine||'  '||s.program||chr(10)||
       'Module/Action: '||s.module||' / '||s.action||chr(10)||
       'Status       : '||s.status||'    Last call: '||s.last_call_et||'s ago    Logon: '||to_char(s.logon_time,'YYYY-MM-DD HH24:MI:SS')||chr(10)||
       'Wait/CPU     : '||decode(s.state,'WAITING', s.event||' ('||s.wait_class||', '||round(s.wait_time_micro/1e6,1)||'s)',
                                 'ON CPU (last wait: '||s.event||')')||chr(10)||
       'Blocked by   : '||nvl2(s.blocking_session, 'SID '||s.blocking_session||' (instance '||s.blocking_instance||')', '-')||chr(10)||
       'SQL_ID       : '||nvl(s.sql_id,'-')||' child '||nvl(to_char(s.sql_child_number),'-')||
       '    exec start: '||nvl(to_char(s.sql_exec_start,'HH24:MI:SS'),'-')||'    prev SQL_ID: '||nvl(s.prev_sql_id,'-')
  from v$session s left join v$process p on p.addr = s.paddr
 where __SW__;
prompt
prompt ===== PL/SQL
select 'Entry point  : '||nvl((select o.owner||'.'||o.object_name from dba_objects o where o.object_id = s.plsql_entry_object_id),'-')||
       nvl((select '.'||x.procedure_name from dba_procedures x
             where x.object_id = s.plsql_entry_object_id and x.subprogram_id = s.plsql_entry_subprogram_id
               and x.procedure_name is not null),'')||
       nvl((select '  ['||o.object_type||']' from dba_objects o where o.object_id = s.plsql_entry_object_id),'')||chr(10)||
       'Executing now: '||nvl((select o.owner||'.'||o.object_name from dba_objects o where o.object_id = s.plsql_object_id),'-')||
       nvl((select '.'||x.procedure_name from dba_procedures x
             where x.object_id = s.plsql_object_id and x.subprogram_id = s.plsql_subprogram_id
               and x.procedure_name is not null),'')||
       nvl((select '  ['||o.object_type||']' from dba_objects o where o.object_id = s.plsql_object_id),'')
  from v$session s where __SW__;
prompt
prompt ===== SQL TEXT  (&v_what, sql_id &v_sqlid)
select sql_fulltext from v$sql where sql_id = '&v_sqlid' and rownum = 1;
prompt
prompt ===== EXECUTION PLAN  (sql_id &v_sqlid, child &v_chld)
select plan_table_output from table(dbms_xplan.display_cursor('&v_sqlid', &v_chld, 'TYPICAL')) where '&v_sqlid' is not null;
prompt
prompt ===== TOP WAIT EVENTS (since logon, non-idle)
prompt EVENT                                          WAITS      TIME(s)
select rpad(event,45)||lpad(total_waits,12)||lpad(to_char(round(time_waited_micro/1e6,2),'999999990.00'),14)
  from (select event, total_waits, time_waited_micro from v$session_event
         where sid = __SID__ and wait_class <> 'Idle' order by time_waited_micro desc)
 where rownum <= 10;
prompt
prompt ===== SESSION STATISTICS (since logon; CPU in centiseconds)
select rpad(n.name,45)||lpad(to_char(st.value,'999,999,999,999,990'),22)
  from v$sesstat st join v$statname n on n.statistic# = st.statistic#
 where st.sid = __SID__
   and n.name in ('CPU used by this session','session logical reads','physical reads','physical writes',
                  'redo size','execute count','parse count (hard)','bytes sent via SQL*Net to client')
 order by n.name;
exit
SQL
    my $sw = defined $conname ? qq{alter session set container = "$conname";} : '';
    $sql =~ s/__SWITCH__/$sw/;
    $sql =~ s/__W__/sid = $ssid and serial# = $serial/g;
    $sql =~ s/__SW__/s.sid = $ssid and s.serial# = $serial/g;
    $sql =~ s/__SID__/$ssid/g;
    return $sql;
}

# ------------------------------------------------------------------ helpers
sub slurp {
    my $f = shift;
    open(my $fh, '<', $f) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_file {
    my ($f, $c) = @_;
    open(my $fh, '>', $f) or die "cannot write $f: $!\n";
    print $fh $c;
    close $fh;
}

sub fmt   { my ($v, $d) = @_; return '-' unless defined $v && $v ne ''; return sprintf('%.*f', $d, $v) }
sub mb    { my $b = shift; return defined $b ? sprintf('%.0f', $b / 1048576) : '-' }
sub min   { $_[0] < $_[1] ? $_[0] : $_[1] }
sub max   { $_[0] > $_[1] ? $_[0] : $_[1] }
sub human {
    my $v = shift;
    return '-' unless defined $v;
    return $v >= 1e9 ? sprintf('%.1fG', $v / 1e9)
         : $v >= 1e6 ? sprintf('%.1fM', $v / 1e6)
         : $v >= 1e4 ? sprintf('%.1fK', $v / 1e3)
         :             sprintf('%.0f', $v);
}
sub rate {
    my ($cur, $prev, $el) = @_;
    return undef unless defined $cur && defined $prev && $el > 0;
    my $x = ($cur - $prev) / $el;
    return $x < 0 ? undef : $x;
}
sub flash { ($msg, $msg_t) = ($_[0], time) }
sub clean { my $s = shift // ''; $s =~ tr/\t/ /; $s =~ s/[\x00-\x1f\x7f]//g; return $s }

sub conname {
    my ($d, $con) = @_;
    return '-' if !defined $con || $con eq 'BG';
    return $d->{pdb}{$con}{name} if $d && $d->{pdb} && $d->{pdb}{$con};
    return $con eq '0' ? 'CDB' : "con $con";
}

sub is_cdb { my $d = $_[0]{db} || {}; return ($d->{cdb} // '') eq 'YES' }

# ------------------------------------------------------------------ OS collection
sub find_home {
    my ($sid, $pid) = @_;
    my $exe = readlink("/proc/$pid/exe");
    return $1 if $exe && $exe =~ m{^(.*)/bin/oracle(?: \(deleted\))?$};
    if (defined(my $env = slurp("/proc/$pid/environ"))) {
        for (split /\0/, $env) { return $1 if /^ORACLE_HOME=(.+)$/ }
    }
    for my $f ('/etc/oratab', '/var/opt/oracle/oratab') {
        open(my $fh, '<', $f) or next;
        while (<$fh>) {
            next if /^\s*(#|$)/;
            my ($s, $h) = split /:/;
            if (defined $h && ($s eq $sid || $sid =~ /^\Q$s\E_?\d+$/)) { close $fh; return $h }
        }
        close $fh;
    }
    return $ENV{ORACLE_HOME};
}

sub collect_os {
    my $now = time;
    my $dt  = defined $last_os_t ? $now - $last_os_t : 0;
    $last_os_t = $now;
    my (%procs, %pmon, %np);

    opendir(my $dh, '/proc') or die "cannot read /proc: $!\n";
    while (defined(my $pid = readdir $dh)) {
        next unless $pid =~ /^\d+$/;
        my $cmd = slurp("/proc/$pid/cmdline");
        next unless defined $cmd && $cmd =~ /^ora/;
        $cmd =~ tr/\0/ /;
        $cmd =~ s/\s+$//;
        my ($sid, $pname);
        if    ($cmd =~ /^ora_([a-z0-9]{4})_(\S+)/)  { ($pname, $sid) = ($1, $2) }
        elsif ($cmd =~ /^oracle(\S+)(?:\s|$)/)      { $sid = $1; $pname = $cmd =~ /LOCAL=NO/ ? 'remote' : 'local' }
        else  { next }

        my $st = slurp("/proc/$pid/stat");
        next unless defined $st;
        my @f = split ' ', substr($st, rindex($st, ')') + 2);
        my ($ticks, $start) = ($f[11] + $f[12], $f[19]);
        my ($res, $shr) = (split ' ', (slurp("/proc/$pid/statm") // '0 0 0'))[1, 2];
        my ($rb, $wb) = (0, 0);
        if (defined(my $io = slurp("/proc/$pid/io"))) {
            $rb = $1 if $io =~ /^read_bytes:\s*(\d+)/m;
            $wb = $1 if $io =~ /^write_bytes:\s*(\d+)/m;
        }
        my $p = { pid => $pid, pname => $pname, cmd => $cmd, priv => max(0, ($res - $shr) * $PAGE) };
        my $pv = $prevproc{$pid};
        if ($pv && $pv->{start} eq $start && $dt > 0) {
            $p->{cpu} = max(0, ($ticks - $pv->{ticks}) / $CLK / $dt * 100);
            $p->{io}  = max(0, (($rb - $pv->{rb}) + ($wb - $pv->{wb})) / $dt);
        }
        $np{$pid} = { start => $start, ticks => $ticks, rb => $rb, wb => $wb };
        push @{ $procs{$sid} }, $p;
        $pmon{$sid} = $pid if $pname eq 'pmon';
    }
    closedir $dh;
    %prevproc = %np;

    for my $sid (keys %inst) { delete $inst{$sid} unless $pmon{$sid} }
    for my $sid (keys %pmon) {
        next if %only && !$only{$sid};
        my $I = $inst{$sid} ||= { sid => $sid };
        if (!$I->{pmon} || $I->{pmon} != $pmon{$sid}) {
            $I->{pmon} = $pmon{$sid};
            $I->{home} = find_home($sid, $pmon{$sid});
            delete $I->{db};
            delete $prevdb{$sid};
        }
        my $pl = $procs{$sid} || [];
        $I->{procs} = $pl;
        my ($cpu, $priv, $io, $have) = (0, 0, 0, 0);
        for (@$pl) {
            $priv += $_->{priv};
            next unless defined $_->{cpu};
            $cpu += $_->{cpu}; $io += $_->{io}; $have = 1;
        }
        $I->{nproc} = scalar @$pl;
        $I->{priv}  = $priv;
        $I->{cpu}   = $have ? $cpu : undef;
        $I->{osio}  = $have ? $io  : undef;
    }

    # host
    if (defined(my $la = slurp('/proc/loadavg'))) { $host{load} = join ' ', (split ' ', $la)[0 .. 2] }
    if (defined(my $mi = slurp('/proc/meminfo'))) {
        for my $k (qw(MemTotal MemAvailable HugePages_Total HugePages_Free Hugepagesize)) {
            $host{$k} = $1 if $mi =~ /^$k:\s+(\d+)/m;
        }
    }
    if (defined(my $ps = slurp('/proc/stat'))) {
        $host{ncpu} = () = $ps =~ /^cpu\d+/mg;
        if ($ps =~ /^cpu\s+(.*)$/m) {
            my @c = split ' ', $1;
            my $tot = 0;
            $tot += $_ for grep { defined } @c[0 .. 7];
            my ($idle, $iow) = ($c[3], $c[4] // 0);
            if ($prev_hcpu && (my $d = $tot - $prev_hcpu->[0]) > 0) {
                $host{cpu} = 100 * ($d - ($idle - $prev_hcpu->[1]) - ($iow - $prev_hcpu->[2])) / $d;
                $host{iow} = 100 * ($iow - $prev_hcpu->[2]) / $d;
            }
            $prev_hcpu = [$tot, $idle, $iow];
        }
    }
    $host{name} ||= (POSIX::uname())[1];
}

# ------------------------------------------------------------------ DB collection
sub run_sqlplus {
    my ($jobs, $timeout) = @_;
    my $sel = IO::Select->new;
    my %byfd;
    STDOUT->flush;
    for my $j (@$jobs) {
        $j->{out} = '';
        my $pid = open(my $fh, '-|');
        if (!defined $pid) { $j->{err} = "fork failed: $!"; next }
        if ($pid == 0) {
            eval {
                $ENV{ORACLE_SID}  = $j->{sid};
                $ENV{ORACLE_HOME} = $j->{home};
                $ENV{LD_LIBRARY_PATH} = "$j->{home}/lib"
                    . ((defined $ENV{LD_LIBRARY_PATH} && length $ENV{LD_LIBRARY_PATH}) ? ":$ENV{LD_LIBRARY_PATH}" : '');
                delete @ENV{qw(TWO_TASK ORACLE_PDB_SID SQLPATH ORACLE_PATH)};
                chdir $TMP;
                open(STDERR, '>&', \*STDOUT);
                open(STDIN, '<', '/dev/null');
                exec { "$j->{home}/bin/sqlplus" } 'sqlplus', '-s', '-L', $opt{connect}, '@' . $j->{file};
            };
            syswrite(STDOUT, "ERROR: cannot exec $j->{home}/bin/sqlplus\n");
            POSIX::_exit(127);
        }
        $j->{pid} = $pid;
        $j->{fh}  = $fh;
        $byfd{ fileno $fh } = $j;
        $sel->add($fh);
    }
    my $deadline = time + $timeout;
    while ($sel->count) {
        my $left = $deadline - time;
        last if $left <= 0;
        for my $fh ($sel->can_read($left)) {
            my $j = $byfd{ fileno $fh };
            my $n = sysread($fh, my $chunk, 65536);
            if ($n) { $j->{out} .= $chunk; next }
            $sel->remove($fh);
            close $fh;
        }
    }
    for my $fh ($sel->handles) {          # timed out
        my $j = $byfd{ fileno $fh };
        kill 'KILL', $j->{pid};
        $sel->remove($fh);
        close $fh;
        $j->{err} = "timeout after ${timeout}s (instance hung?)";
    }
    delete $_->{fh} for @$jobs;
}

sub collect_db {
    my ($do_inst, $do_detail) = @_;
    my @jobs;
    if ($do_inst) {
        for my $sid (sort keys %inst) {
            my $I = $inst{$sid};
            if (!$I->{home} || !-x "$I->{home}/bin/sqlplus") {
                $I->{db} = { err => 'ORACLE_HOME not found (not readable / not in oratab)', pdb => {}, sess => {} };
                next;
            }
            push @jobs, { kind => 'inst', sid => $sid, home => $I->{home}, file => $INST_SQL };
        }
    }
    if ($do_detail && $detail && $inst{ $detail->{isid} }) {
        write_file($DETAIL_SQL, detail_sql($detail->{ssid}, $detail->{serial}, $detail->{conname}));
        push @jobs, { kind => 'detail', sid => $detail->{isid}, home => $inst{ $detail->{isid} }{home}, file => $DETAIL_SQL };
    }
    my $t0 = time;
    run_sqlplus(\@jobs, $opt{timeout});
    for my $j (@jobs) {
        if ($j->{kind} eq 'inst') { parse_inst($j, $t0) }
        else {
            my @l = map { clean($_) } split /\n/, $j->{out};
            pop @l while @l && $l[-1] =~ /^\s*$/;
            shift @l while @l && $l[0] =~ /^\s*$/;
            unshift @l, "ERROR: $j->{err}", '' if $j->{err};
            $detail->{lines} = \@l;
        }
    }
    attach($_) for values %inst;
}

sub parse_inst {
    my ($j, $t0) = @_;
    my $sid = $j->{sid};
    my $I = $inst{$sid} or return;
    my %d = (pdb => {}, sess => {}, Y => {}, Z => {}, T => {}, cnt => {});
    my $firsterr;
    for my $line (split /\n/, $j->{out}) {
        $line =~ s/\s+$//;
        if ($line =~ /^([IVBGPYZDTS])\|(.*)$/) {
            my ($tag, @f) = ($1, split(/\|/, $2, -1));
            if    ($tag eq 'I') { @d{qw(name version istatus startup)} = @f }
            elsif ($tag eq 'V') { $d{version} = $f[0] if length $f[0] }
            elsif ($tag eq 'B') { @d{qw(cdb open_mode role)} = @f }
            elsif ($tag eq 'G') { $d{sga} = $f[0] }
            elsif ($tag eq 'P') { $d{pga} = $f[0] }
            elsif ($tag eq 'Y') { $d{Y}{ $f[0] } = $f[1] }
            elsif ($tag eq 'Z') { $d{Z}{ $f[0] } = $f[1] }
            elsif ($tag eq 'T') { $d{T}{ $f[0] }{ $f[1] } = $f[2] }
            elsif ($tag eq 'D') { $d{pdb}{ $f[0] } = { con => $f[0], name => $f[1], open => $f[2], mb => $f[3] } }
            elsif ($tag eq 'S') {
                my %s;
                @s{qw(spid sid serial con user status sql_id event module type pga et wclass blk state me)} = @f;
                my $old = $d{sess}{ $s{spid} };
                $d{sess}{ $s{spid} } = \%s if !$old || ($old->{type} ne 'USER' && $s{type} eq 'USER');
                if ($s{type} eq 'USER' && $s{me} ne 'Y') {
                    $d{cnt}{ $s{con} }{tot}++;
                    $d{cnt}{ $s{con} }{act}++ if $s{status} eq 'ACTIVE';
                    $d{tot}++;
                    $d{act}++ if $s{status} eq 'ACTIVE';
                }
            }
        }
        elsif (!defined $firsterr && $line =~ /((?:ORA|SP2|TNS)-\d+.*)/) { $firsterr = $1 }
    }
    if (!defined $d{name}) {
        $d{err} = $j->{err} || $firsterr || 'no output from sqlplus';
        $I->{db} = \%d;
        delete $prevdb{$sid};
        return;
    }
    my $p = $prevdb{$sid};
    if ($p && $p->{startup} eq $d{startup}) {
        my $el = $t0 - $p->{t};
        my $aas = rate($d{Y}{'DB time'}, $p->{Y}{'DB time'}, $el);
        my $cpu = rate($d{Y}{'DB CPU'},  $p->{Y}{'DB CPU'},  $el);
        $d{aas}   = defined $aas ? $aas / 1e6 : undef;
        $d{dbcpu} = defined $cpu ? $cpu / 1e6 : undef;
        my $rb = rate($d{Z}{'physical read total bytes'},  $p->{Z}{'physical read total bytes'},  $el);
        my $wb = rate($d{Z}{'physical write total bytes'}, $p->{Z}{'physical write total bytes'}, $el);
        $d{io}   = (defined $rb && defined $wb) ? ($rb + $wb) / 1048576 : undef;
        $d{lio}  = rate($d{Z}{'session logical reads'}, $p->{Z}{'session logical reads'}, $el);
        $d{exec} = rate($d{Z}{'execute count'},         $p->{Z}{'execute count'},         $el);
        for my $con (keys %{ $d{T} }) {
            my $pt = $p->{T}{$con} or next;
            my $c  = $d{pdb}{$con} or next;
            my $a  = rate($d{T}{$con}{'DB time'}, $pt->{'DB time'}, $el);
            my $u  = rate($d{T}{$con}{'DB CPU'},  $pt->{'DB CPU'},  $el);
            $c->{aas}   = defined $a ? $a / 1e6 : undef;
            $c->{dbcpu} = defined $u ? $u / 1e6 : undef;
        }
    }
    $prevdb{$sid} = { t => $t0, startup => $d{startup}, Y => $d{Y}, Z => $d{Z}, T => $d{T} };
    $I->{db} = \%d;
}

# map OS processes -> sessions -> containers
sub attach {
    my $I = shift;
    my $d = $I->{db} ||= { pdb => {}, sess => {} };
    my $sess = $d->{sess} || {};
    my %byc;
    for my $p (@{ $I->{procs} || [] }) {
        my $s = $sess->{ $p->{pid} };
        $p->{s}   = $s;
        $p->{con} = ($s && $s->{type} eq 'USER') ? $s->{con} : 'BG';
        my $b = $byc{ $p->{con} } ||= { cpu => undef, priv => 0, pga => 0, n => 0 };
        $b->{n}++;
        $b->{priv} += $p->{priv};
        $b->{pga}  += ($s ? ($s->{pga} || 0) : 0);
        $b->{cpu} = ($b->{cpu} // 0) + $p->{cpu} if defined $p->{cpu};
    }
    $d->{byc} = \%byc;
}

sub refresh {
    collect_os();
    collect_db(1, $mode eq 'detail' || ($mode eq 'help' && grep { $_ eq 'detail' } @stack));
}

# ------------------------------------------------------------------ views
sub sorted {
    my ($key, $fn, $name, @items) = @_;
    return sort { $name->($a) cmp $name->($b) } @items if $key eq 'n';
    return sort { ($fn->($b) // -1) <=> ($fn->($a) // -1) or $name->($a) cmp $name->($b) } @items;
}

sub inst_status {
    my $d = shift;
    return 'ERR'   if $d->{err};
    return '...'   unless defined $d->{istatus};
    return 'NOMNT' if $d->{istatus} eq 'STARTED';
    my %m = ('READ WRITE' => 'RW', 'READ ONLY' => 'RO', 'READ ONLY WITH APPLY' => 'ROAP', 'MOUNTED' => 'MNT');
    my $s = $m{ $d->{open_mode} // '' } // ($d->{open_mode} // '?');
    $s .= '/S' if ($d->{role} // '') =~ /STANDBY/;
    return $s;
}

my $IFMT = "%-12.12s %-11.11s %-3.3s %4s %-6.6s %5s %9s %6s %8s %7s %7s %6s %6s %8s %8s %8s";
sub view_inst {
    my $hdr = sprintf $IFMT, qw(SID VERSION CDB PDBS STATUS PROCS ACT/SESS %CPU PRIV_MB SGA_MB PGA_MB AAS DBCPU IO_MB/s LIO/s EXEC/s);
    my %fn = (
        c => sub { $_[0]{cpu} },
        m => sub { my $d = $_[0]{db} || {}; ($d->{sga} // 0) + ($d->{pga} // 0) + $_[0]{priv} / 1048576 },
        a => sub { my $d = $_[0]{db} || {}; $d->{aas} // $d->{act} },
        o => sub { ($_[0]{db} || {})->{io} },
        e => sub { $_[0]{cpu} },
    );
    my @I = sorted($sortk{inst}, $fn{ $sortk{inst} }, sub { $_[0]{sid} }, values %inst);
    my (@keys, @lines);
    for my $I (@I) {
        my $d = $I->{db} || {};
        my $npdb = is_cdb($I) ? scalar(grep { /^\d+$/ && $_ > 2 } keys %{ $d->{pdb} }) : '-';
        my $line = sprintf $IFMT, $I->{sid}, $d->{version} // '-', $d->{cdb} // '-', $npdb, inst_status($d),
            $I->{nproc}, defined $d->{tot} || defined $d->{name} ? sprintf('%d/%d', $d->{act} // 0, $d->{tot} // 0) : '-',
            fmt($I->{cpu}, 1), mb($I->{priv}), $d->{sga} // '-', $d->{pga} // '-',
            fmt($d->{aas}, 2), fmt($d->{dbcpu}, 2), fmt($d->{io}, 1), human($d->{lio}), human($d->{exec});
        my $st = '';
        if ($d->{err}) { $line .= "  $d->{err}"; $st = 'w' }
        push @keys, $I->{sid};
        push @lines, [$line, $st];
    }
    return (\@keys, $hdr, \@lines);
}

my $PFMT = "%-5s %-24.24s %-11.11s %9s %6s %5s %8s %7s %6s %6s %8s";
sub view_pdb {
    my $sid = shift;
    my $I = $inst{$sid} or return ([], 'instance is gone', []);
    my $d = $I->{db} || {};
    my $hdr = sprintf $PFMT, qw(CON NAME OPEN_MODE ACT/SESS %CPU PROCS PRIV_MB PGA_MB AAS DBCPU SIZE_GB);
    my $byc = $d->{byc} || {};
    my @cons = (keys %{ $d->{pdb} }, 'BG');
    my %fn = (
        c => sub { ($byc->{ $_[0] } || {})->{cpu} },
        m => sub { my $b = $byc->{ $_[0] } || {}; ($b->{pga} // 0) + ($b->{priv} // 0) / 1048576 },
        a => sub { $_[0] eq 'BG' ? -1 : (($d->{pdb}{ $_[0] } || {})->{aas} // ($d->{cnt}{ $_[0] } || {})->{act}) },
        o => sub { ($byc->{ $_[0] } || {})->{cpu} },
        e => sub { ($byc->{ $_[0] } || {})->{cpu} },
    );
    my @sorted = sorted($sortk{pdb}, $fn{ $sortk{pdb} }, sub { $_[0] eq 'BG' ? 'zzz' : sprintf('%06d', $_[0]) }, @cons);
    my (@keys, @lines);
    for my $con (@sorted) {
        my $c = $d->{pdb}{$con} || {};
        my $b = $byc->{$con} || {};
        my $n = $d->{cnt}{$con} || {};
        my $line = sprintf $PFMT,
            $con eq 'BG' ? '-' : $con,
            $con eq 'BG' ? '(background / no session)' : $c->{name},
            $con eq 'BG' ? '' : $c->{open},
            $con eq 'BG' ? '-' : sprintf('%d/%d', $n->{act} // 0, $n->{tot} // 0),
            fmt($b->{cpu}, 1), $b->{n} // 0, mb($b->{priv}), fmt($b->{pga}, 0),
            fmt($c->{aas}, 2), fmt($c->{dbcpu}, 2), defined $c->{mb} ? sprintf('%.1f', $c->{mb} / 1024) : '-';
        push @keys, $con;
        push @lines, [$line, ($n->{act} ? 'a' : '')];
    }
    return (\@keys, $hdr, \@lines);
}

my $RFMT = "%7s %6s %7s %7s %8s %-12.12s %-14.14s %-16.16s %1s %-13.13s %6s  %s";
sub view_proc {
    my ($sid, $con) = @_;
    my $I = $inst{$sid} or return ([], 'instance is gone', []);
    my $d = $I->{db} || {};
    my $hdr = sprintf $RFMT, 'PID', '%CPU', 'PRIV_MB', 'PGA_MB', 'IO_KB/s', 'SID,SERIAL', 'PDB', 'USERNAME', 'S', 'SQL_ID', 'ET(s)', 'ACTIVITY';
    my @p = @{ $I->{procs} || [] };
    @p = grep { ($_->{con} // 'BG') eq $con } @p if defined $con;
    if ($only_active) {
        @p = grep {
            my $s = $_->{s};
            ($_->{cpu} // 0) >= 0.5 || ($s && $s->{type} eq 'USER' && $s->{status} eq 'ACTIVE' && $s->{me} ne 'Y')
        } @p;
    }
    my %fn = (
        c => sub { $_[0]{cpu} },
        m => sub { $_[0]{priv} / 1048576 + ($_[0]{s} ? ($_[0]{s}{pga} || 0) : 0) },
        a => sub { my $s = $_[0]{s}; ($s && $s->{status} eq 'ACTIVE' && $s->{type} eq 'USER') ? 1e6 + ($_[0]{cpu} // 0) : ($_[0]{cpu} // 0) },
        o => sub { $_[0]{io} },
        e => sub { my $s = $_[0]{s}; ($s && $s->{type} eq 'USER' && $s->{status} eq 'ACTIVE') ? $s->{et} : -1 },
    );
    my @sorted = sorted($sortk{proc}, $fn{ $sortk{proc} }, sub { sprintf('%010d', $_[0]{pid}) }, @p);
    my (@keys, @lines);
    for my $p (@sorted) {
        my $s = $p->{s};
        my ($sess, $user, $st, $sqlid, $et, $act, $style) = ('-', '-', '-', '-', '-', $p->{cmd}, '');
        if ($s) {
            $sess  = "$s->{sid},$s->{serial}";
            $sqlid = $s->{sql_id};
            if ($s->{type} eq 'USER') {
                $user = $s->{user} . ($s->{me} eq 'Y' ? ' (cdbtop)' : '');
                $st   = $s->{status} eq 'ACTIVE' ? 'A' : 'I';
                $et   = $s->{et};
                $act  = ($st eq 'A' ? ($s->{state} eq 'WAITING' ? $s->{event} : 'ON CPU') . '  ' : '') . "[$s->{module}]";
                $style = $st eq 'A' && $s->{me} ne 'Y' ? ($s->{blk} ne '-' ? 'w' : 'a') : '';
                $act .= "  blocked by SID $s->{blk}" if $s->{blk} ne '-';
            }
            else {
                $user = "($p->{pname})";
                $st   = 'B';
                $act  = $s->{state} eq 'WAITING' ? $s->{event} : 'ON CPU';
            }
        }
        my $line = sprintf $RFMT, $p->{pid}, fmt($p->{cpu}, 1), mb($p->{priv}), $s ? fmt($s->{pga}, 1) : '-',
            defined $p->{io} ? sprintf('%.0f', $p->{io} / 1024) : '-',
            $sess, $s && $s->{type} eq 'USER' ? conname($d, $s->{con}) : '-', $user, $st, $sqlid, $et, clean($act);
        push @keys, $p->{pid};
        push @lines, [$line, $style];
    }
    return (\@keys, $hdr, \@lines);
}

sub detail_view_lines {
    my $avail = shift;
    my @src = @{ ($detail && $detail->{lines}) || ['(loading ...)'] };
    my @l;
    for my $orig (@src) {
        my $s = $orig;
        $s =~ s/\s+$//;
        my $st = $s =~ /^===== / ? 'b' : $s =~ /^(ERROR|\*\*\*)/ ? 'w' : '';
        if ($wrap && length($s) > $W) {
            push @l, [substr($s, 0, $W, ''), $st] while length($s) > $W;
        }
        push @l, [$s, $st];
    }
    my $maxs = max(0, @l - $avail);
    $detail->{scroll} = min(max(0, $detail->{scroll} // 0), $maxs);
    $page_rows = max(1, $avail - 1);
    my $from = $detail->{scroll};
    return @l[$from .. min($#l, $from + $avail - 1)];
}

sub help_lines {
    return split /\n/, <<'EOT';

  cdbtop - top for Oracle CDB / PDB instances        Instances -> Containers -> Processes -> Session detail

  Navigation
    Up/Down  j/k         move selection             PgUp/PgDn  Home/End    page / jump
    Enter  Right         drill down                 Esc  Left  Backspace  b    go back
    p                    process list of selected instance (all containers) or of selected container
    s  Enter (procs)     session detail: current SQL text, PL/SQL entry/current object, plan, waits, stats

  Sorting (descending)   c CPU   m memory   a active sessions / AAS   o I/O   e elapsed (procs)   n name/id

  Other
    i  (procs)           toggle: show only busy (>=0.5% CPU) or ACTIVE processes
    w  (detail)          toggle line wrap
    + / -                refresh interval up / down      r or Space    refresh now
    ? h                  this help                       q             quit

  Columns
    %CPU      OS CPU of the processes since last refresh, top-style (100 = one full core)
    PRIV_MB   private resident memory of the processes (SGA / shared memory not included)
    SGA_MB    v$sga   PGA_MB  v$pgastat 'total PGA allocated' (procs/containers: v$process.pga_alloc_mem)
    AAS       average active sessions   = delta(DB time) / elapsed        (v$sys_time_model / v$con_sys_time_model)
    DBCPU     CPU of DB calls in cores  = delta(DB CPU)  / elapsed
    IO_MB/s   physical read+write total bytes per second (v$sysstat)     LIO/s logical reads   EXEC/s executions
    ACT/SESS  active / total user sessions          S  A=active I=inactive B=background
    Status    RW / RO / ROAP (read only with apply) / MNT / NOMNT, "/S" = standby

  Press any key to return.
EOT
}

# ------------------------------------------------------------------ screen
sub header_lines {
    my @t  = localtime;
    my $l1 = sprintf('cdbtop %s - %02d:%02d:%02d  host %s  load %s  cpus %d  host cpu %s%%  iowait %s%%',
        $VERSION, @t[2, 1, 0], $host{name} // '?', $host{load} // '-', $host{ncpu} // 0,
        fmt($host{cpu}, 1), fmt($host{iow}, 1));
    my $hp = ($host{HugePages_Total} // 0) ? sprintf('  hugepages %d/%d free', $host{HugePages_Free}, $host{HugePages_Total}) : '';
    my $l2 = sprintf('mem %.1fG total, %.1fG avail%s  |  instances %d  |  refresh %ss  |  sort %s%s',
        ($host{MemTotal} // 0) / 1048576, ($host{MemAvailable} // 0) / 1048576, $hp, scalar(keys %inst),
        $opt{delay}, $SORTNAME{ $sortk{ $mode =~ /^(inst|pdb|proc)$/ ? $mode : 'proc' } },
        $only_active && $mode eq 'proc' ? '  |  only busy' : '');

    my @crumb = ('Instances');
    my $m = $mode eq 'help' ? ($stack[-1] // 'inst') : $mode;
    if ($m ne 'inst') {
        my $I = $inst{ $ctx{sid} // '' };
        push @crumb, $ctx{sid} // '?';
        push @crumb, 'Containers' if $m eq 'pdb';
        if ($m eq 'proc' || $m eq 'detail') {
            push @crumb, defined $ctx{con} ? conname($I && $I->{db}, $ctx{con}) . ($ctx{con} eq 'BG' ? ' (background)' : '') : 'all containers';
            push @crumb, 'Processes';
        }
        push @crumb, "Session $detail->{ssid},$detail->{serial} (pid $detail->{spid}, $detail->{conlabel})" if $m eq 'detail';
    }
    my %hint = (
        inst   => 'Enter containers  p processes  c/m/a/o/n sort  +/- delay  ? help  q quit',
        pdb    => 'Enter/p processes  Esc back  c/m/a/n sort  ? help  q quit',
        proc   => 'Enter/s SQL detail  i only busy  c/m/a/o/e/n sort  Esc back  ? help  q quit',
        detail => 'Up/Dn PgUp/PgDn scroll  w wrap  r refresh  Esc back  q quit',
        help   => '',
    );
    my $l4 = (time - $msg_t < 5 && $msg) ? [$msg, 'w'] : [$hint{$mode}, ''];
    return ([$l1, 'h'], [$l2, ''], [join('  >  ', @crumb), 'b'], $l4);
}

sub render {
    my @out = header_lines();
    my $avail = max(1, $H - @out);
    if ($mode eq 'help') {
        @out = ([$out[0][0], 'h'], map { [$_, ''] } help_lines());
    }
    elsif ($mode eq 'detail') {
        push @out, detail_view_lines($avail);
    }
    else {
        my ($keys, $hdr, $lines) =
              $mode eq 'inst' ? view_inst()
            : $mode eq 'pdb'  ? view_pdb($ctx{sid})
            :                   view_proc($ctx{sid}, $ctx{con});
        push @out, [$hdr, 'r'];
        my $rows = max(1, $avail - 1);
        my $n = @$keys;
        my $idx;
        if (defined $selk{$mode}) {
            for my $i (0 .. $n - 1) { if ($keys->[$i] eq $selk{$mode}) { $idx = $i; last } }
        }
        $idx = min($lastidx{$mode} // 0, max(0, $n - 1)) unless defined $idx;
        $selk{$mode} = $n ? $keys->[$idx] : undef;
        ($cur_keys, $cur_idx, $page_rows, $lastidx{$mode}) = ($keys, $idx, $rows, $idx);
        my $o = $off{$mode} // 0;
        $o = $idx if $idx < $o;
        $o = $idx - $rows + 1 if $idx >= $o + $rows;
        $o = max(0, min($o, $n - $rows));
        $off{$mode} = $o;
        for my $i ($o .. min($n - 1, $o + $rows - 1)) {
            push @out, [$lines->[$i][0], $i == $idx ? 's' : $lines->[$i][1]];
        }
        push @out, ['  (nothing to show)', ''] unless $n;
    }
    draw(\@out);
}

sub draw {
    my $out = shift;
    my $buf = "\e[H";
    for my $i (0 .. $H - 1) {
        my ($t, $st) = @{ $out->[$i] // ['', ''] };
        $t  = clean($t);
        $st //= '';
        $t  = substr($t, 0, $W) if length($t) > $W;
        $t .= ' ' x ($W - length $t) if $st eq 'r' || $st eq 's';
        $buf .= $STY{$st} . $t . "\e[0m";
        $buf .= "\e[K" if length($t) < $W;
        $buf .= "\r\n" if $i < $H - 1;
    }
    print $buf;
}

sub get_size {
    my $s = `stty size < /dev/tty 2>/dev/null`;
    if ($s && $s =~ /^(\d+)\s+(\d+)/ && $1 > 0 && $2 > 0) { ($H, $W) = ($1, $2) }
}

sub term_init {
    $TTY_SAVE = `stty -g < /dev/tty`;
    chomp $TTY_SAVE;
    system('stty -icanon -echo min 1 time 0 < /dev/tty');
    STDOUT->autoflush(1);
    print "\e[?1049h\e[?25l\e[2J";
    get_size();
}

sub term_reset {
    return unless defined $TTY_SAVE && $$ == $MAIN_PID;
    system("stty $TTY_SAVE < /dev/tty");
    print "\e[0m\e[?25h\e[?1049l";
    undef $TTY_SAVE;
}
END { term_reset() }

# ------------------------------------------------------------------ input
sub handle_input {
    my $buf = shift;
    while (length $buf) {
        my $k;
        if    ($buf =~ s/^\e[\[O]([ABCD])//) { $k = { A => 'UP', B => 'DOWN', C => 'RIGHT', D => 'LEFT' }->{$1} }
        elsif ($buf =~ s/^\e\[(\d+)~//)      { $k = { 1 => 'HOME', 4 => 'END', 5 => 'PGUP', 6 => 'PGDN', 7 => 'HOME', 8 => 'END' }->{$1} }
        elsif ($buf =~ s/^\e[\[O]([HF])//)   { $k = $1 eq 'H' ? 'HOME' : 'END' }
        elsif ($buf =~ s/^\e//)              { $k = 'ESC' }
        else {
            $k = substr($buf, 0, 1, '');
            $k = 'ENTER' if $k eq "\n" || $k eq "\r";
            $k = 'BACK'  if $k eq "\x7f" || $k eq "\b";
        }
        key($k) if defined $k;
    }
}

sub move {
    my $n = shift;
    return unless @$cur_keys;
    my $i = max(0, min($#$cur_keys, $cur_idx + $n));
    ($selk{$mode}, $cur_idx) = ($cur_keys->[$i], $i);
}

sub go_back {
    return unless @stack;
    $mode = pop @stack;
}

sub key {
    my $k = shift;
    if ($mode eq 'help') { go_back(); return }
    exit 0 if $k eq 'q' || $k eq 'Q';
    if ($k eq '?' || $k eq 'h') { push @stack, $mode; $mode = 'help'; return }
    if ($k eq '+') { $opt{delay}++; flash("refresh interval $opt{delay}s"); return }
    if ($k eq '-') { $opt{delay} = max(1, $opt{delay} - 1); flash("refresh interval $opt{delay}s"); return }
    if ($k eq 'r' || $k eq ' ') { $force = 1; return }
    if ($k =~ /^(?:ESC|LEFT|BACK|b)$/) { go_back(); return }

    if ($mode eq 'detail') {
        my %mv = (UP => -1, k => -1, DOWN => 1, j => 1, PGUP => -$page_rows, PGDN => $page_rows, HOME => -1e9, g => -1e9, END => 1e9, G => 1e9);
        if (exists $mv{$k}) { $detail->{scroll} = max(0, ($detail->{scroll} // 0) + $mv{$k}) }
        elsif ($k eq 'w')   { $wrap = !$wrap }
        return;
    }

    my %mv = (UP => -1, k => -1, DOWN => 1, j => 1, PGUP => -$page_rows, PGDN => $page_rows, HOME => -1e9, END => 1e9);
    if (exists $mv{$k}) { move($mv{$k}); return }
    if ($k =~ /^[cmaoen]$/) { $sortk{$mode} = $k; return }
    if ($k eq 'i' && $mode eq 'proc') { $only_active = !$only_active; return }

    my $sel = $selk{$mode};
    return unless defined $sel;
    if ($mode eq 'inst') {
        if ($k eq 'ENTER' || $k eq 'RIGHT' || $k eq 'p') {
            $ctx{sid} = $sel;
            $ctx{con} = undef;
            push @stack, 'inst';
            $mode = ($k ne 'p' && is_cdb($inst{$sel})) ? 'pdb' : 'proc';
            delete @selk{qw(pdb proc)};
            delete @lastidx{qw(pdb proc)};
        }
    }
    elsif ($mode eq 'pdb') {
        if ($k eq 'ENTER' || $k eq 'RIGHT' || $k eq 'p') {
            $ctx{con} = $sel;
            push @stack, 'pdb';
            $mode = 'proc';
            delete $selk{proc};
            delete $lastidx{proc};
        }
    }
    elsif ($mode eq 'proc') {
        enter_detail($sel) if $k eq 'ENTER' || $k eq 'RIGHT' || $k eq 's';
    }
}

sub enter_detail {
    my $pid = shift;
    my $I = $inst{ $ctx{sid} } or return;
    my ($p) = grep { $_->{pid} eq $pid } @{ $I->{procs} || [] };
    my $s = $p && $p->{s};
    unless ($s) { flash("process $pid has no database session"); return }
    my $d   = $I->{db} || {};
    my $con = $s->{con};
    my $conname = ($con =~ /^\d+$/ && $con > 2 && $d->{pdb}{$con}) ? $d->{pdb}{$con}{name} : undef;
    $detail = { isid => $ctx{sid}, ssid => $s->{sid}, serial => $s->{serial}, conname => $conname,
                conlabel => conname($d, $con), spid => $pid, scroll => 0, lines => ['(loading ...)'] };
    push @stack, 'proc';
    $mode = 'detail';
    render();
    collect_db(0, 1);
}

# ------------------------------------------------------------------ batch mode
sub batch {
    $W = 250;
    collect_os(); collect_db(1, 0);
    sleep(min(2, $opt{delay}));
    for my $i (1 .. $opt{iter}) {
        sleep $opt{delay} if $i > 1;
        collect_os(); collect_db(1, 0);
        print POSIX::strftime("=== cdbtop %Y-%m-%d %H:%M:%S", localtime), "  host $host{name}  load $host{load}\n";
        my (undef, $h, $l) = view_inst();
        print "$h\n", map { "$_->[0]\n" } @$l;
        for my $sid (sort keys %inst) {
            next unless is_cdb($inst{$sid});
            my (undef, $h2, $l2) = view_pdb($sid);
            print "\n[$sid]\n$h2\n", map { "$_->[0]\n" } @$l2;
        }
        print "\n";
    }
}

# ------------------------------------------------------------------ main
if ($opt{batch}) { batch(); exit 0 }
-t STDIN && -t STDOUT or die "cdbtop needs a terminal (use -b for batch output)\n";

$SIG{INT} = $SIG{TERM} = $SIG{HUP} = sub { exit 0 };
$SIG{WINCH} = sub { $winch = 1 };
$SIG{PIPE}  = 'IGNORE';

term_init();
flash('collecting first sample ...');
render();
refresh();
my $next = time + 1;                   # second sample soon -> deltas available quickly
my $in = IO::Select->new(\*STDIN);
while (1) {
    if ($winch) { $winch = 0; get_size(); print "\e[2J" }
    render();
    if ($force || time >= $next) {
        $force = 0;
        refresh();
        $next = time + $opt{delay};
        next;
    }
    if ($in->can_read(max(0.05, $next - time))) {
        my $n = sysread(STDIN, my $buf, 256);
        exit 0 if defined $n && $n == 0;
        handle_input($buf) if $n;
    }
}
