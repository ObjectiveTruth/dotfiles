
# Loads Homeshick so you can call from console
source "$HOME/.homesick/repos/homeshick/homeshick.sh"

#After any ! command that executes history. Command is placed in CMD instead of excuted
shopt -s histverify

# Sets the maximum number of lines to remember in .bash_history
HISTSIZE=5000
HISTFILESIZE=50000

# Loads Completions
for f in $(find -L $HOME/.homesick/repos/dotfiles/bash_completions/ -type f -name '*.bash')
do
  source $f
done

# Enable Vi Mode in Bash
set -o vi

# Sets the prompt
# Not used for now, see how the gitprompt.sh works out
set_prompt () {
    Last_Command=$? # Must come first!
    Blue='\[\e[01;34m\]'
    White='\[\e[01;37m\]'
    Red='\[\e[01;31m\]'
    Green='\[\e[01;32m\]'
    Reset='\[\e[00m\]'
    FancyX='\342\234\227'
    Checkmark='\342\234\223'

    # Add a bright white exit status for the last command
    PS1="$White\$? "
    # If it was successful, print a green check mark. Otherwise, print
    # a red X.
    if [[ $Last_Command == 0 ]]; then
        PS1+="$Green$Checkmark "
    else
        PS1+="$Red$FancyX "
    fi
    # If root, just print the host in red. Otherwise, print the current user
    # and host in green.
    if [[ $EUID == 0 ]]; then
        PS1+="$Red\\h "
    else
        PS1+="$Green\\u@\\h "
    fi
    # Print the working directory and prompt marker in blue, and reset
    # the text color to the default.
    PS1+="$Blue\\w \n\\\$$Reset "
}
# Customization for bash-git-prompt as per https://github.com/magicmonty/bash-git-prompt
GIT_PROMPT_FETCH_REMOTE_STATUS=0
GIT_PROMPT_THEME=Solarized

# Activate bash-git-prompt
source $HOME/.homesick/repos/dotfiles/bash-git-prompt/gitprompt.sh

# If the gitprompt.sh fails, fall back to a still nice command prompt
if [ $? -ne 0 ] ; then PROMPT_COMMAND='set_prompt' ; fi

