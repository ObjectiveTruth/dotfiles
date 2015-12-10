
" Turns on syntax highlighting
syntax on

" Sets up all the tabs to be spaces (soft-tabs)
set expandtab
set tabstop=4
set shiftwidth=4

" Remaps ESC to jj
imap jj <Esc>

" Sets the line number
set number

" sets the colorscheme
colors molokai

" removes highlighting search terms after you hit enter after /
:set nohlsearch

" Set current directory to current file
set autochdir

" Tell vim to be aware of the filetype being edited, used in conjunction with syntax on
filetype on
