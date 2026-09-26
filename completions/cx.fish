# fish completion for cx
#
#   cx completion fish > ~/.config/fish/completions/cx.fish
#
# NO NETWORK WORK, EVER. Hosts come from ~/.config/cx/ssh.d, targets from
# ~/.cache/cx/targets (any listing), sessions and their state from
# ~/.cache/cx/state (cx peek, cx bar), goal names from ~/.cache/cx/goals.
#
# Fish replaces the whole token, so a target's ':' needs none of the care
# bash does. Keep the command and flag lists in step with cx.bash's tables.

function __cx_dir
    if set -q CX_CACHE_DIR
        echo $CX_CACHE_DIR
    else
        echo $HOME/.cache/cx
    end
end

function __cx_hosts
    set -l d $HOME/.config/cx/ssh.d
    set -q CX_SSHD_DIR; and set d $CX_SSHD_DIR
    test -d $d; or return
    for f in $d/*.conf
        printf '%s\tserver\n' (basename $f .conf)
    end
end

# __cx_targets [live|known] — target<TAB>state, sessions included.
function __cx_targets
    set -l d (__cx_dir)
    set -l s $d/state
    switch "$argv[1]"
        case live
            test -s $s; and awk -F'\t' '$2 != "dead" { print $1 "\t" $2 }' $s; and return
        case known
            test -s $s; and awk -F'\t' '{ print $1 "\t" $2 }' $s; and return
    end
    test -r $s; and awk -F'\t' '{ print $1 "\t" $2 }' $s
    test -r $d/targets; and awk '{ print $0 "\tproject" }' $d/targets
    for h in (__cx_hosts | string replace -r '\t.*' '')
        printf '%s:\tserver\n' $h
    end
end

function __cx_goals
    set -l f (__cx_dir)/goals
    test -r $f; and awk -F'\t' '!seen[$2]++ { print $2 "\t" $3 " on " $1 }' $f
end

function __cx_ssh_hosts
    set -l cfg $HOME/.ssh/config
    set -q CX_SSH_CONFIG; and set cfg $CX_SSH_CONFIG
    test -r $cfg; and awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' $cfg
end

# The words after `cx` that are not global flags — which may come anywhere.
function __cx_words
    for w in (commandline -opc)[2..-1]
        switch $w
            case -r --refresh --no-cache --stale --json -y --yes --no-color
                continue
            case worktree
                echo wt
            case '*'
                echo $w
        end
    end
end

function __cx_pos
    __cx_words | string match -v -- '-*'
end

function __cx_needs_command
    test (count (__cx_pos)) -eq 0
end

# __cx_using CMD... — the command is one of these.
function __cx_using
    set -l p (__cx_pos)
    test (count $p) -ge 1; and contains -- $p[1] $argv
end

# __cx_needs_sub CMD — CMD given, its subverb not yet.
function __cx_needs_sub
    set -l p (__cx_pos)
    test (count $p) -eq 1; and test "$p[1]" = $argv[1]
end

# __cx_sub CMD SUB... — CMD given with one of these subverbs.
function __cx_sub
    set -l p (__cx_pos)
    test (count $p) -ge 2; and test "$p[1]" = $argv[1]; and contains -- $p[2] $argv[2..-1]
end

complete -c cx -f

# Global flags, anywhere.
complete -c cx -s r -l refresh -d 'force a fetch, ignoring the cache'
complete -c cx -l no-cache -d 'bypass the cache without updating it'
complete -c cx -l stale -d 'accept cached data of any age'
complete -c cx -l json -d 'machine-readable output'
complete -c cx -s y -l yes -d 'assume yes to prompts'
complete -c cx -l no-color -d 'disable color'

# Commands.
for c in \
    'host	manage servers' \
    'provision	install or update the agent' \
    'login	one-time Claude Code sign-in' \
    'doctor	check requirements and connectivity' \
    'new	create a project' \
    'ls	list projects and worktrees' \
    'rm	unregister a project' \
    'wt	worktrees for parallel tasks' \
    'worktree	worktrees for parallel tasks' \
    'open	attach a Claude session' \
    'resume	attach and pick a past conversation' \
    'shell	plain shell, no Claude' \
    'code	open in VS Code over Remote-SSH' \
    'ask	one-shot question' \
    'status	live sessions' \
    'stop	end a session' \
    'forget	drop a finished session from the lists' \
    'peek	what each session is doing now' \
    'nudge	send a prompt to a running session' \
    'bar	one line for a tmux status bar' \
    'tabs	a tmux tab per live session, here' \
    'jump	go to the tab of the session that needs you' \
    'goal	definitions of done for your sessions' \
    'driver	print the cx-driver subagent' \
    'cache	inspect or drop cached data' \
    'completion	print the shell completion script' \
    'find	pick a target interactively' \
    'pick	pick a target interactively' \
    'help	show usage' \
    'version	print the version'
    set -l kv (string split \t -- $c)
    complete -c cx -n __cx_needs_command -a $kv[1] -d $kv[2]
end

# Subverbs.
complete -c cx -n '__cx_needs_sub host' -a 'add import ls test edit rm'
complete -c cx -n '__cx_needs_sub wt' -a 'add ls rm'
complete -c cx -n '__cx_needs_sub goal' -a 'new ls show dod member pause resume done log on-stop rm'
complete -c cx -n '__cx_needs_sub cache' -a 'status clear refresh'

# Arguments.
complete -c cx -n '__cx_sub host test edit rm; or __cx_using provision login doctor ls; or __cx_sub cache clear refresh' -a '(__cx_hosts)'
complete -c cx -n '__cx_sub host import' -a '(__cx_ssh_hosts)'
complete -c cx -n '__cx_using new' -a '(__cx_hosts | string replace -r "^([^\t]*)" "\$1:")'
complete -c cx -n '__cx_using open resume shell code ask peek rm find pick; or __cx_sub wt ls rm' -a '(__cx_targets)'
complete -c cx -n '__cx_sub wt add' -a '(__cx_targets | string match -v -r "[/@]" | string replace -r "^([^\t]*:[^\t]+)\t.*" "\$1/")'
complete -c cx -n '__cx_using stop nudge' -a '(__cx_targets live)'
complete -c cx -n '__cx_using forget' -a '(__cx_targets known)'
complete -c cx -n '__cx_sub goal show dod pause resume done log on-stop rm member' -a '(__cx_goals)'
complete -c cx -n '__cx_sub goal member' -a 'add rm'
complete -c cx -n '__cx_using completion' -a 'bash zsh fish'

# Per-command flags.
complete -c cx -n '__cx_sub host add' -l alias -x -d 'short name you will type'
complete -c cx -n '__cx_sub host add' -l hostname -x -d 'address or DNS name'
complete -c cx -n '__cx_sub host add' -l user -x -d 'login user'
complete -c cx -n '__cx_sub host add' -l port -x -d 'SSH port'
complete -c cx -n '__cx_sub host add' -l identity -r -F -d 'private key file'
complete -c cx -n '__cx_sub host add; or __cx_sub host import; or __cx_using new' -l root -x -d 'project root on the server'
complete -c cx -n '__cx_sub host add' -l no-test -d 'skip the connection check'
complete -c cx -n '__cx_using provision' -s a -l all -d 'every server'
complete -c cx -n '__cx_using new' -l repo -x -d 'clone this repository'
complete -c cx -n '__cx_using new; or __cx_sub wt add' -l open -d 'open it once created'
complete -c cx -n '__cx_using new; or __cx_sub wt add' -l no-open -d 'do not open it, and do not ask'
complete -c cx -n '__cx_using new; or __cx_sub wt add' -s d -l detach -d 'open it, but do not attach'
complete -c cx -n '__cx_using new; or __cx_sub wt add' -l label -x -d 'open it as a named session'
complete -c cx -n '__cx_using ls' -l git -d 'show git branch and state'
complete -c cx -n '__cx_using ls; or __cx_sub host ls; or __cx_sub wt ls' -s f -l filter -x -d 'only what matches'
complete -c cx -n '__cx_using ls' -l host -x -a '(__cx_hosts)' -d 'only this server'
complete -c cx -n '__cx_using ls' -l live -d 'only projects with a live session'
complete -c cx -n '__cx_using ls' -l active -x -d 'touched within (30m, 2h, 7d)'
complete -c cx -n '__cx_using ls' -l idle -x -d 'not touched within (30m, 2h, 7d)'
complete -c cx -n '__cx_using ls' -l dirty -d 'only uncommitted changes'
complete -c cx -n '__cx_using ls' -l no-worktrees -d 'projects only'
complete -c cx -n '__cx_using ls' -l group -x -a 'host none' -d 'layout'
complete -c cx -n '__cx_using ls' -l sort -x -a 'name active sessions host none' -d 'order'
complete -c cx -n '__cx_sub host ls' -l reachable -d 'only servers last seen up'
complete -c cx -n '__cx_sub host ls' -l down -d 'only servers last seen down'
complete -c cx -n '__cx_using rm' -l purge -d 'also delete the files'
complete -c cx -n '__cx_sub wt add' -l branch -x -d 'branch name'
complete -c cx -n '__cx_sub wt add' -l from -x -d 'what to branch from'
complete -c cx -n '__cx_sub wt rm' -l force -d 'discard uncommitted changes'
complete -c cx -n '__cx_sub wt rm' -l merged -d 'every merged worktree'
complete -c cx -n '__cx_using open resume shell' -s d -l detach -d 'start it, do not attach'
complete -c cx -n '__cx_using open resume shell new; or __cx_sub wt add' -l no-hooks -d 'without the hooks that report its state'
complete -c cx -n '__cx_using open resume ask new; or __cx_sub wt add' -l permission-mode -x -a 'acceptEdits auto bypassPermissions manual dontAsk plan' -d 'how much Claude asks'
complete -c cx -n '__cx_using open resume ask new; or __cx_sub wt add' -l dangerously-skip-permissions -d 'bypass ALL permission checks'
complete -c cx -n '__cx_using open resume ask new; or __cx_sub wt add; or __cx_sub goal on-stop' -l model -x -a 'opus sonnet haiku' -d 'model'
complete -c cx -n '__cx_using open resume ask new; or __cx_sub wt add' -l effort -x -a 'low medium high xhigh max' -d 'reasoning effort'
complete -c cx -n '__cx_using ask' -l output-format -x -a 'text json stream-json' -d 'output format'
complete -c cx -n '__cx_using ask' -l json-schema -x -d 'JSON Schema for structured output'
complete -c cx -n '__cx_using ask' -l max-budget-usd -x -d 'cap what this call may spend'
complete -c cx -n '__cx_using stop' -l all -d 'every session of the project'
complete -c cx -n '__cx_using peek' -l all -d 'list finished sessions too'
complete -c cx -n '__cx_using peek' -l tail -x -d 'include the last N messages in --json'
complete -c cx -n '__cx_using peek' -l goal -x -a '(__cx_goals)' -d "just that goal's members"
complete -c cx -n '__cx_using nudge' -l force -d 'send it even if the session is busy'
complete -c cx -n '__cx_using bar' -l setup -d 'print tmux configuration'
complete -c cx -n '__cx_using bar' -l plain -d 'no tmux styling'
complete -c cx -n '__cx_using bar' -l attached -d 'include sessions you have open'
complete -c cx -n '__cx_using bar' -l color -d 'colour the states'
complete -c cx -n '__cx_using bar' -l icons -x -a 'unicode nerd' -d 'icon set'
complete -c cx -n '__cx_using bar' -l window -x -a '(__cx_targets)' -d "one tab's state icon"
complete -c cx -n '__cx_using bar' -l max -x -d 'how many to name'
complete -c cx -n '__cx_using bar' -l label -x -d 'the prefix'
complete -c cx -n '__cx_using bar jump' -l states -x -a 'blocked idle working fresh starting dead unknown' -d 'which states, in order'
complete -c cx -n '__cx_using tabs' -s n -l dry-run -d 'show what it would open'
complete -c cx -n '__cx_using tabs' -l no-attach -d 'build it, do not attach'
complete -c cx -n '__cx_using tabs' -s s -l session -x -d 'tmux session name'
complete -c cx -n '__cx_using tabs' -l take -d 'open sessions held elsewhere too'
complete -c cx -n '__cx_using find pick' -s p -l print -d 'print the target instead of opening it'
complete -c cx -n '__cx_using goal' -l host -x -a '(__cx_hosts)' -d 'the server holding the goal'
complete -c cx -n '__cx_sub goal new' -l member -x -a '(__cx_targets)' -d 'a session working on it'
complete -c cx -n '__cx_sub goal ls' -l state -x -a 'active paused done' -d 'only goals in this state'
complete -c cx -n '__cx_sub goal log' -l event -x -d 'event kind'
complete -c cx -n '__cx_sub goal log' -l target -x -a '(__cx_targets)' -d 'the session it concerns'
complete -c cx -n '__cx_sub goal on-stop' -l max -x -d 'runs an hour at most'
complete -c cx -n '__cx_sub goal on-stop' -l off -d 'stop driving itself'
