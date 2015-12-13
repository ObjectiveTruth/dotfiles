
# Loads Homeshick so you can call from console
source "$HOME/.homesick/repos/homeshick/homeshick.sh"

# Loads Completions
for f in $(find -L $HOME/.homesick/repos/dotfiles/bash_completions/ -type f -name '*.bash')
do
  source $f
done

