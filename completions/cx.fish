# fish completion for cx
#
# Targets come from ~/.cache/cx/targets, refreshed by any cx listing.
# No network work happens during completion.

function __cx_targets
    set -l f (test -n "$CX_CACHE_DIR"; and echo $CX_CACHE_DIR; or echo $HOME/.cache/cx)/targets
    test -r $f; and cat $f
end

function __cx_hosts
    set -l d (test -n "$CX_SSHD_DIR"; and echo $CX_SSHD_DIR; or echo $HOME/.config/cx/ssh.d)
    test -d $d; or return
    for f in $d/*.conf
        basename $f .conf
    end
end

complete -c cx -f

complete -c cx -n __fish_use_subcommand -a host      -d 'manage servers'
complete -c cx -n __fish_use_subcommand -a provision -d 'install or update the agent'
complete -c cx -n __fish_use_subcommand -a login     -d 'one-time Claude Code sign-in'
complete -c cx -n __fish_use_subcommand -a doctor    -d 'check requirements'
complete -c cx -n __fish_use_subcommand -a new       -d 'create a project'
complete -c cx -n __fish_use_subcommand -a ls        -d 'list projects'
complete -c cx -n __fish_use_subcommand -a rm        -d 'remove a project'
complete -c cx -n __fish_use_subcommand -a open      -d 'attach a Claude session'
complete -c cx -n __fish_use_subcommand -a resume    -d 'pick a past conversation'
complete -c cx -n __fish_use_subcommand -a shell     -d 'plain shell'
complete -c cx -n __fish_use_subcommand -a code      -d 'open in VS Code'
complete -c cx -n __fish_use_subcommand -a ask       -d 'one-shot question'
complete -c cx -n __fish_use_subcommand -a status    -d 'live sessions'
complete -c cx -n __fish_use_subcommand -a stop      -d 'end a session'
complete -c cx -n __fish_use_subcommand -a cache     -d 'inspect cached data'
complete -c cx -n __fish_use_subcommand -a wt        -d 'worktrees for parallel tasks'
complete -c cx -n __fish_use_subcommand -a worktree  -d 'worktrees for parallel tasks'

complete -c cx -n '__fish_seen_subcommand_from open resume shell code ask stop rm' -a '(__cx_targets)'
complete -c cx -n '__fish_seen_subcommand_from provision login doctor cache ls' -a '(__cx_hosts)'
complete -c cx -n '__fish_seen_subcommand_from host' -a 'add import ls test edit rm'
complete -c cx -n '__fish_seen_subcommand_from wt worktree' -a 'add ls rm'
complete -c cx -n '__fish_seen_subcommand_from wt worktree' -a '(__cx_targets)'
complete -c cx -n '__fish_seen_subcommand_from wt worktree' -l branch -d 'branch name'
complete -c cx -n '__fish_seen_subcommand_from wt worktree' -l from -d 'what to branch from'
complete -c cx -n '__fish_seen_subcommand_from wt worktree' -l force -d 'discard uncommitted changes'

complete -c cx -l refresh -s r -d 'force a fetch'
complete -c cx -l no-cache -d 'bypass the cache'
complete -c cx -l stale -d 'accept cached data of any age'
complete -c cx -l json -d 'machine-readable output'
complete -c cx -s y -l yes -d 'assume yes'
complete -c cx -n '__fish_seen_subcommand_from stop' -l all -d 'every session of the project'
complete -c cx -n '__fish_seen_subcommand_from open resume ask' \
    -l dangerously-skip-permissions -d 'bypass ALL permission checks'
