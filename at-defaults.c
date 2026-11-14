/*
 * The at system's own settings, part of every Windows build: tmux as
 * at-terminal, the at menu and the home tools expect it. The server reads no
 * configuration file, so every server starts the same (TMUX-210).
 *
 * Options take these values as their defaults, so set -u returns to them. User
 * options and key bindings are commands run with tmux's own default bindings,
 * before any client and before the snapshot from which upgrade-server tells
 * this build's defaults from what was set later (TMUX-207).
 */

#include <sys/types.h>

#include <stdlib.h>
#include <string.h>

#include "tmux.h"

#ifdef _WIN32

static const struct {
	const char	*name;
	const char	*value;
} at_options[] = {
	/*
	 * Windows numbered from 1 and closing up, the mouse, a long history, no
	 * prefix (Ctrl+B is the at menu), and no timer redrawing the status line
	 * (TMUX-112). at-terminal (Windows Terminal 1.25) speaks the kitty keyboard
	 * protocol and synchronized output but never names itself, so both are
	 * asked for.
	 */
	{ "base-index",
	  "1" },
	{ "renumber-windows",
	  "on" },
	{ "default-terminal",
	  "tmux-256color" },
	{ "mouse",
	  "on" },
	{ "history-limit",
	  "50000" },
	{ "pane-border-lines",
	  "simple" },
	{ "pane-active-border-style",
	  "default" },
	{ "detach-on-destroy",
	  "off" },
	{ "status-interval",
	  "0" },
	{ "extended-keys",
	  "on" },
	{ "terminal-features[90]",
	  "xterm-256color:extkeys" },
	{ "terminal-overrides[90]",
	  "xterm-256color:Eneks=\\E[>1u:Dseks=\\E[<u" },
	{ "terminal-features[91]",
	  "xterm-256color:sync" },
	{ "prefix",
	  "None" },

	/*
	 * A window is named by the title its program sets, else by the program;
	 * pwsh, its folder-name title and the hostname count as no title. A Claude
	 * or Codex window takes the short name its hooks set (HOMECFG-129).
	 */
	{ "automatic-rename-format",
	  "#{?#{@codex-title},#{@codex-title},#{?#{@claude-title},#{@claude-title},#{?#{==:#{pane_current_command},claude},#{s/^[^ -~]+ //:pane_title},#{?#{||:#{==:#{pane_current_command},pwsh},#{||:#{==:#{pane_title},#{b:pane_current_path}},#{==:#{pane_title},#{host_short}}}},#{pane_current_command},#{pane_title}}}}}" },

	/*
	 * Claude Code's bypass permissions label is hidden (TMUX-183).
	 */
	{ "pane-hidden-text[0]",
	  "\xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle) \xc2\xb7 " },
	{ "pane-hidden-text[1]",
	  "\xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on (shift+tab to cycle)" },
	{ "pane-hidden-text[2]",
	  "\xe2\x8f\xb5\xe2\x8f\xb5 bypass permissions on" },

	/*
	 * A Claude or Codex pane's conversation strip on its bottom row (TMUX-83),
	 * drawn by the @strip formats below.
	 */
	{ "pane-footer",
	  "#{?#{e|<:#{pane_width},36},#{E:@r-small},#{E:@r-big}}" },
	{ "pane-footer-condition",
	  "#{&&:#{@strip-active},#{==:#{@strip-active},#{E:@strip-session}}}" },

	/*
	 * The primary session opens a shell window when its last one closes.
	 */
	{ "session-created[1]",
	  "if-shell -F \"#{==:#{session_name},primary}\" { set-option keep-alive-window autolaunched }" },
	{ "session-renamed[0]",
	  "if-shell -F \"#{==:#{session_name},primary}\" { set-option keep-alive-window autolaunched } { set-option -u keep-alive-window }" },

	/*
	 * Commands in the at menu, each with its description and search words.
	 * tmux's own move-window is movew in them, since move-window is an alias.
	 */
	{ "command-alias[100]",
	  "move-window=run-shell -C \"#{E:@move-window}\"" },
	{ "command-alias-note[100]",
	  "move-window=Send this window to another session" },
	{ "command-alias[101]",
	  "bring-to-session=run-shell -C \"#{E:@bring-to-session}\"" },
	{ "command-alias-note[101]",
	  "bring-to-session=Send this window to another session and go there with it" },
	{ "command-alias[102]",
	  "reorder-window=display-menu -T \" reorder window \" -x C -y C Front f { movew -b -t :^ ; movew -r } Forward w { if -F \"#{window_start_flag}\" {} { swapw -t :-1 ; selectw -t :-1 } } Backward s { if -F \"#{window_end_flag}\" {} { swapw -t :+1 ; selectw -t :+1 } } Back b { movew -a -t :$ ; movew -r }" },
	{ "command-alias-note[102]",
	  "reorder-window=Move this window to the front, the back, or one place either way" },
	{ "command-alias[130]",
	  "window-nav=command-prompt -T window-target { select-window -t '%%' }" },
	{ "command-alias-note[130]",
	  "window-nav=Go to a window by searching for it" },
	{ "command-alias-tags[130]",
	  "window-nav=go switch window tab find nav" },
	{ "command-alias[113]",
	  "claude-for-this-app=run-shell -C \"#{E:@work-on-app} claude\"" },
	{ "command-alias-note[113]",
	  "claude-for-this-app=Start Claude in the repo of the app in this tab" },
	{ "command-alias-tags[113]",
	  "claude-for-this-app=claude agent start app repo" },
	{ "command-alias[114]",
	  "codex-for-this-app=run-shell -C \"#{E:@work-on-app} codex\"" },
	{ "command-alias-note[114]",
	  "codex-for-this-app=Start Codex in the repo of the app in this tab" },
	{ "command-alias-tags[114]",
	  "codex-for-this-app=codex agent start app repo" },
	{ "command-alias[111]",
	  "claude-relaunch-with-chrome=if -F '#{@claude-session}' { run-shell -C 'respawn-pane -k -c \"#{@claude-cwd}\" \"#{@fzt-automate}\" resume-claude #{@claude-session} --chrome' } { display-message 'No Claude session in this window' }" },
	{ "command-alias-note[111]",
	  "claude-relaunch-with-chrome=Restart this window's Claude session with Claude in Chrome connected" },
	{ "command-alias-tags[111]",
	  "claude-relaunch-with-chrome=claude agent chrome browser restart relaunch" },
	{ "command-alias[115]",
	  "reload-app=if -F '#{@codex-session}' { run-shell -C 'respawn-pane -k -c \"#{@codex-cwd}\" #{s/[^a-z]id[^a-z]/#{@codex-session}/:@session-set-resume-codex}' } { if -F '#{@claude-session}' { run-shell -C 'respawn-pane -k -c \"#{@claude-cwd}\" #{s/[^a-z]id[^a-z]/#{@claude-session}/:@session-set-resume}' } { respawn-pane -k } }" },
	{ "command-alias-note[115]",
	  "reload-app=Restart the app in this pane, resuming a Claude or Codex conversation" },
	{ "command-alias-tags[115]",
	  "reload-app=reload restart relaunch app claude codex" },
	{ "command-alias[116]",
	  "toggle-bypass-label=if -F '#{pane-hidden-text}' { set -gu pane-hidden-text[0] ; set -gu pane-hidden-text[1] ; set -gu pane-hidden-text[2] } { set -gu pane-hidden-text }" },
	{ "command-alias-note[116]",
	  "toggle-bypass-label=Show or hide Claude Code's bypass permissions label" },
	{ "command-alias-tags[116]",
	  "toggle-bypass-label=claude bypass permissions label show hide" },
	{ "command-alias[117]",
	  "toggle-agent-sounds=if -F '#{command-alias[90]}' { set -su command-alias[90] ; display-message 'Agent sounds on' } { set -s command-alias[90] 'play-sound=play-sound -s muted' ; display-message 'Agent sounds muted' }" },
	{ "command-alias-note[117]",
	  "toggle-agent-sounds=Mute or unmute Claude and Codex sounds until toggled again" },
	{ "command-alias-tags[117]",
	  "toggle-agent-sounds=sound sounds mute unmute audio quiet notification claude codex agent" },
	{ "command-alias[112]",
	  "system-session=if -F '#{S:#{?#{==:#{session_name},system},1,}}' {} { new-session -d -s system -n mail tuimail.exe '' ; set -w -t system:mail @mail-window 1 ; set -w -t system:mail remain-on-exit relaunch ; new-window -d -b -M spotify -t system:^ -o remain-on-exit=relaunch spotify_player.exe -c //NelsonNAS/spt-config ; new-window -d -M alerts -t system: -o remain-on-exit=relaunch alerts.exe view ; set -t system bell-action none }" },
	{ "command-alias-note[112]",
	  "system-session=Make the system session whole: mail, spotify and alerts" },
	{ "command-alias-tags[112]",
	  "system-session=system session mail spotify alerts" },
	{ "command-alias[120]",
	  "links=run-shell -b \"#{E:@strip-menu}\"" },
	{ "command-alias-note[120]",
	  "links=Show this conversation\xe2\x80\x99s PRs, work packages and history" },
	{ "command-alias-tags[120]",
	  "links=links pr prs ticket followup history strip conversation" },
};

static const char *const at_commands[] = {
	/*
	 * Prefix keys: t a new window, 9 the last one, b hides the window bar. The
	 * status-left menu has nothing to click on the window bar.
	 */
	"unbind C-b",
	"bind t new-window",
	"bind 9 last-window",
	"bind b if -F '#{==:#{status},off}' 'set -g status on' 'set -g status off'",
	"unbind -n MouseDown3StatusLeft",
	"unbind -n M-MouseDown3StatusLeft",

	/*
	 * A full-screen program that leaves the mouse to tmux gets the wheel as
	 * arrow keys (AHT-11).
	 */
	"bind -n WheelUpPane if -F -t = '#{||:#{pane_in_mode},#{mouse_any_flag}}' { send -M } { if -F -t = '#{alternate_on}' { send -t = -N 3 Up } { copy-mode -e -t = } }",
	"bind -n WheelDownPane if -F -t = '#{||:#{pane_in_mode},#{mouse_any_flag}}' { send -M } { if -F -t = '#{alternate_on}' { send -t = -N 3 Down } }",

	/*
	 * Windows-style keys: Ctrl+Tab, Ctrl+1..9, Ctrl+W, Ctrl+Shift+PgUp/PgDn,
	 * Ctrl+N, Ctrl+` between sessions, Ctrl+Shift+T reopening the last window.
	 */
	"bind -n C-Tab next-window",
	"bind -n C-BTab previous-window",
	"bind -n C-1 select-window -t 1",
	"bind -n C-2 select-window -t 2",
	"bind -n C-3 select-window -t 3",
	"bind -n C-4 select-window -t 4",
	"bind -n C-5 select-window -t 5",
	"bind -n C-6 select-window -t 6",
	"bind -n C-7 select-window -t 7",
	"bind -n C-8 select-window -t 8",
	"bind -n C-9 last-window",
	"bind -n -N 'Close the active pane, or the window when it has only one' C-w if -F '#{>:#{window_panes},1}' { run-shell -C 'confirm-before -p \"close pane #{?@claude-session,claude,#{?@codex-session,codex,#{pane_current_command}}}? (y/n)\" \"kill-pane -t #{pane_id}\"' } { confirm-before -p \"close window #W? (y/n)\" kill-window }",
	"bind -n C-S-PPage swap-window -t -1 \\; select-window -t -1",
	"bind -n C-S-NPage swap-window -t +1 \\; select-window -t +1",
	"bind -n C-n command-prompt -p \"new session name:\" \"new-session -s '%%'\"",
	"bind -n 'C-`' switch-client -n -O index",
	"bind -n 'C-~' switch-client -p -O index",
	"bind -n 'C-S-`' switch-client -p -O index",
	"bind -n -N 'Reopen the window closed last' C-S-t reopen-window",

	/*
	 * What move-window and bring-to-session run.
	 */
	"set -g @move-window '#{?#{==:#{server_sessions},2},movew -t \"=#{S:#{?#{==:#{session_name},#{client_session}},,#{session_name}}}:\",display-menu -T \" move window to \" -x C -y C #{S:#{?#{==:#{session_name},#{client_session}},,\"#{session_name}\" \"#{s/^(.).*/\\1/:session_name}\" \"movew -t \\\"=#{session_name}:\\\"\" }}}'",
	"set -g @bring-to-session '#{?#{==:#{server_sessions},2},#{S:#{?#{==:#{session_name},#{client_session}},,movew -t \"=#{session_name}:\" ; switch-client -t \"=#{session_name}\"}},display-menu -T \" bring window to \" -x C -y C #{S:#{?#{==:#{session_name},#{client_session}},,\"#{session_name}\" \"#{s/^(.).*/\\1/:session_name}\" \"movew -t \\\"=#{session_name}:\\\" ; switch-client -t \\\"=#{session_name}\\\"\" }}}'",

	/*
	 * The at menu (SHELL-247): Ctrl+B opens it at its tmux folder, Alt+Tab and
	 * Alt+Shift+Tab at its open windows (TMUX-209), which at-terminal hands to
	 * tmux while it is in front.
	 */
	"set -g @fzt-automate 'C:/Program Files/at-home/fzt-automate/current/fzt-automate.exe'",
	"set -g @at-menu 'display-palette -b none -w 90% -h 80% \"#{@fzt-automate}\" --popup --window \"#{window_id}\" --client \"#{client_name}\"'",
	"bind -n C-b run-shell -C '#{E:@at-menu} --open tmux'",
	"bind -n M-Tab run-shell -C '#{E:@at-menu} --open windows'",
	"bind -n M-BTab run-shell -C '#{E:@at-menu} --open windows'",
	"bind -T panel / display-palette -P -b none -w 60% -h 60% 'C:/Program Files/at-home/fzt/current/fzt.exe' -tiered -accept-nth 4 -layout reverse -border -title 'Side panel commands'",

	/*
	 * Ctrl+T chords (keys pressed while Ctrl stays held): a plain window on
	 * release, or a window on the at menu (+a), Claude (+c), Codex (+o), or an
	 * agent in the repo of the app in this tab (+r, +e). @claude-app is the app
	 * a Claude window runs, which fzt-automate reads (ATC-7).
	 */
	"set -g @claude-app at-claude",
	"bind -n C-t switch-client -T ctrl-t -H -R new-window",
	"bind -T ctrl-t C-a run-shell -C 'new-window -o remain-on-exit=failed \"#{@fzt-automate}\" --run'",
	"bind -T ctrl-t C-c run-shell -C 'new-window -o remain-on-exit=failed \"#{@fzt-automate}\" launch-claude'",
	"bind -T ctrl-t C-o run-shell -C 'new-window -o remain-on-exit=failed \"#{@fzt-automate}\" launch-codex'",
	"set -g @work-on-app 'new-window -a -e AT_ORIGIN_WINDOW=#{window_id} -o remain-on-exit=failed \"#{@fzt-automate}\" work-on-app'",
	"bind -T ctrl-t C-r run-shell -C '#{E:@work-on-app} claude'",
	"bind -T ctrl-t C-e run-shell -C '#{E:@work-on-app} codex'",

	/*
	 * What a restore, reopen-window and reload-app run for an agent's pane.
	 */
	"set -g @session-set-resume '\"C:/Program Files/at-home/fzt-automate/current/fzt-automate.exe\" resume-claude {id}'",
	"set -g @session-set-resume-codex 'codex.exe --no-daemon resume {id}'",

	/*
	 * The conversation strip's formats: strip-owner sets @strip-* on the pane
	 * and these fit them to its width, so nothing runs to draw it (TMUX-133).
	 * A click on it opens the strip's menu; a follow-up's session starts from
	 * the @followup folder and guide (AGT-3).
	 */
	"set -g @strip-session '#{?@codex-session,#{@codex-session},#{@claude-session}}'",
	"set -g @strip-agent '#{?@codex-session,codex,claude}'",
	"set -g @strip-menu 'call \"C:/Program Files/at-home/at-home-tools/current/tmux-strip.exe\" menu --session \"#{E:@strip-session}\" --agent \"#{E:@strip-agent}\" --socket \"#{socket_path}\" --client \"#{client_name}\" --width #{client_width} --height #{client_height}'",
	"set -g @w-who '#{?#{e|>:#{e|/:#{pane_width},6},22},22,#{?#{e|<:#{e|/:#{pane_width},6},6},6,#{e|/:#{pane_width},6}}}'",
	"set -g @wide '#{e|>=:#{pane_width},70}'",
	"set -g @w-fu '#{?@strip-followups,#{e|+:#{w:@strip-followups},3},0}'",
	"set -g @w-ag '#{?@strip-agents,#{e|+:#{w:@strip-agents},3},0}'",
	"set -g @w-rest '#{e|-:#{e|-:#{e|-:#{e|-:#{e|-:#{pane_width},#{E:@w-who}},#{w:@strip-more}},12},#{E:@w-fu}},#{E:@w-ag}}'",
	"set -g @n-pr '#{e|+:#{e|+:#{?@strip-plan,#{e|+:#{w:@strip-plan},1},0},#{w:@strip-pr}},#{?#{E:@wide},2,0}}'",
	"set -g @w-tmin '#{e|+:#{?#{e|<:#{w:@strip-ticket},10},#{w:@strip-ticket},10},#{?#{E:@wide},2,0}}'",
	"set -g @w-pr0 '#{?#{e|<=:#{E:@n-pr},#{e|-:#{E:@w-rest},#{E:@w-tmin}}},#{E:@n-pr},#{e|-:#{E:@w-rest},#{E:@w-tmin}}}'",
	"set -g @w-pr '#{?#{E:@wide},#{e|-:#{E:@w-pr0},2},#{E:@w-pr0}}'",
	"set -g @w-plan '#{?#{e|>:#{w:@strip-plan},#{E:@w-pr}},#{E:@w-pr},#{w:@strip-plan}}'",
	"set -g @w-prtext '#{e|-:#{e|-:#{E:@w-pr},#{E:@w-plan}},#{?@strip-plan,1,0}}'",
	"set -g @w-t1 '#{e|-:#{E:@w-rest},#{E:@w-pr0}}'",
	"set -g @w-ticket '#{?#{E:@wide},#{e|-:#{E:@w-t1},2},#{E:@w-t1}}'",
	"set -g @w-small '#{e|-:#{pane_width},5}'",
	"set -g @c-who '#{?#{e|>:#{w:@strip-who},#{E:@w-who}},#{=/#{e|-:#{E:@w-who},1}/\xe2\x80\xa6:@strip-who},#{@strip-who}}'",
	"set -g @c-plan '#{?#{e|>:#{w:@strip-plan},#{E:@w-plan}},#{=/#{e|-:#{E:@w-plan},1}/\xe2\x80\xa6:@strip-plan},#{@strip-plan}}'",
	"set -g @c-prtext '#{?#{e|<:#{E:@w-prtext},3},,#{?#{e|>:#{w:@strip-pr},#{E:@w-prtext}},#{=/#{e|-:#{E:@w-prtext},1}/\xe2\x80\xa6:@strip-pr},#{@strip-pr}}}'",
	"set -g @c-pr '#{?@strip-plan,#{E:@c-plan}#[fg=#{@strip-pr-colour}]#{?#{E:@c-prtext}, #{E:@c-prtext},},#[fg=#{@strip-pr-colour}]#{E:@c-prtext}}'",
	"set -g @c-ticket '#{?#{e|>:#{w:@strip-ticket},#{E:@w-ticket}},#{=/#{e|-:#{E:@w-ticket},1}/\xe2\x80\xa6:@strip-ticket},#{@strip-ticket}}'",
	"set -g @c-small '#{?@strip-plan,#{?#{e|>:#{w:@strip-plan},#{E:@w-small}},#{=/#{e|-:#{E:@w-small},1}/\xe2\x80\xa6:@strip-plan},#{@strip-plan}},#[fg=#D2A6FF]#{?#{e|>:#{w:@strip-ticket},#{E:@w-small}},#{=/#{e|-:#{E:@w-small},1}/\xe2\x80\xa6:@strip-ticket},#{@strip-ticket}}}'",
	"set -g @r-small ' #[range=user|#{?@strip-plan,pr,ticket}]#{E:@c-small}#[norange,fg=default] #[range=user|links,fg=#8A9199]\xe2\x80\xba#[norange,fg=default]'",
	"set -g @on-copy-pr ' #[range=user|copy-pr,fg=#8A9199]\xee\xaf\x8c#[norange,fg=default]'",
	"set -g @r-copy-pr '#{?#{&&:#{E:@wide},#{@strip-pr-url}},#{E:@on-copy-pr},}'",
	"set -g @on-copy-t ' #[range=user|copy-ticket,fg=#8A9199]\xee\xaf\x8c#[norange,fg=default]'",
	"set -g @r-copy-t '#{?#{&&:#{E:@wide},#{@strip-focus-ticket}},#{E:@on-copy-t},}'",
	"set -g @r-big ' #[range=user|who,fg=#73D0FF]#{E:@c-who}#[norange,fg=default] \xe2\x94\x82 #[range=user|pr]#{E:@c-pr}#[norange,fg=default]#{E:@r-copy-pr} \xe2\x94\x82 #[range=user|ticket,fg=#D2A6FF]#{E:@c-ticket}#[norange,fg=default]#{E:@r-copy-t}#{?@strip-followups, \xe2\x94\x82 #{@strip-followups},}#{?@strip-agents, \xe2\x94\x82 #{@strip-agents},} \xe2\x94\x82 #[range=user|links,fg=#8A9199]#{@strip-more}#[norange,fg=default]'",
	"bind -n MouseDown1Footer select-pane -t = \\; run-shell -b '#{E:@strip-menu} --part \"#{mouse_status_range}\"'",
	"set -g @followup-repos 'D:/repos'",
	"set -g @followup-guide 'S:/shell-config-profile-home/claude/topics/spawned-session.md'",

	/*
	 * Only the at server, the one at-terminal shows: its session set, Win+`,
	 * the alerts listener and strip-owner. A test or throwaway server has none.
	 */
	"if -F '#{m:*-at,#{socket_path}}' { set -g @session-set-dir \"$USERPROFILE/.tmux-session-set\" ; bind -T global 'W-`' if -F '#{global_key_terminal_foreground}' { run-shell -C '#{E:@at-menu}' ; run-shell -C 'system-session' } ; bind -T global-no-client 'W-`' start-program at-terminal.exe ; run-shell -b \"alerts.exe listen -socket #{socket_path}\" ; run-shell -b \"strip-owner.exe start\" }",
};

/* Give a new option the at system's default, where it has one. */
void
at_defaults_option(struct options *oo, struct options_entry *o)
{
	const char	*name = options_name(o), *at;
	size_t		 len = strlen(name);
	char		*cause = NULL;
	u_int		 i;

	for (i = 0; i < nitems(at_options); i++) {
		at = at_options[i].name;
		if (strncmp(at, name, len) != 0)
			continue;
		if (at[len] == '\0') {
			if (options_from_string(oo, options_table_entry(o),
			    name, at_options[i].value, 0, &cause) != 0)
				fatalx("bad at default %s: %s", at, cause);
		} else if (at[len] == '[') {
			if (options_array_set(o, strtoul(at + len + 1, NULL, 10),
			    at_options[i].value, 0, &cause) != 0)
				fatalx("bad at default %s: %s", at, cause);
		}
	}
}

/* Queue the user options and key bindings, after tmux's own bindings. */
void
at_defaults_init(void)
{
	struct cmd_parse_result	*pr;
	u_int			 i;

	for (i = 0; i < nitems(at_commands); i++) {
		pr = cmd_parse_from_string(at_commands[i], NULL);
		if (pr->status != CMD_PARSE_SUCCESS) {
			log_debug("%s", pr->error);
			fatalx("bad at default: %s", at_commands[i]);
		}
		cmdq_append(NULL, cmdq_get_command(pr->cmdlist, NULL));
		cmd_list_free(pr->cmdlist);
	}
}

#endif /* _WIN32 */
