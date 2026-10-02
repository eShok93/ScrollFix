# ScrollFix: optional local input-line selection for zsh emacs keymaps.
# Source only after explicit user setup. No shell startup files are changed here.
# This module never reads files, launches commands, logs input or copies text.
[[ -o interactive ]] || return 0

_scrollfix_select_line_start() {
    (( REGION_ACTIVE )) || MARK=$CURSOR
    zle .beginning-of-line
    REGION_ACTIVE=1
}

_scrollfix_select_line_end() {
    (( REGION_ACTIVE )) || MARK=$CURSOR
    zle .end-of-line
    REGION_ACTIVE=1
}

zle -N scrollfix-select-line-start _scrollfix_select_line_start
zle -N scrollfix-select-line-end _scrollfix_select_line_end
bindkey -M emacs $'\e[1;2H' scrollfix-select-line-start
bindkey -M emacs $'\e[1;2F' scrollfix-select-line-end
# Preserve the user's choice of editing mode; support vi insert mode too.
bindkey -M viins $'\e[1;2H' scrollfix-select-line-start
bindkey -M viins $'\e[1;2F' scrollfix-select-line-end
