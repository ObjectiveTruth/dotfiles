# dotfiles

My public **castle** to be used with the [homeshick](https://github.com/andsens/homeshick) framework for managing dotfiles across computers

## Install

1. Install homeshick from the upstream repo ([homeshick](https://github.com/andsens/homeshick))

  `git clone https://github.com/andsens/homeshick.git $HOME/.homesick/repos/homeshick`

2. Add homeshick to the path (command below assumes bash, see upstream repo for more options)

  `printf '\nsource "$HOME/.homesick/repos/homeshick/homeshick.sh"' >> $HOME/.bashrc`
  
  *Optionally*: reload with `source ~/.bashrc`
  
3. Clone this repo as a castle

  `homeshick clone ObjectiveTruth/dotfiles`
