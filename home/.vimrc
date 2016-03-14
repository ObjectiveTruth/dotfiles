
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

" removes highlighting search terms after you hit enter after /
:set nohlsearch

" Set current directory to current file
set autochdir

" Tell vim to be aware of the filetype being edited, used in conjunction with syntax on
filetype on

" Turn on relative numbers
set relativenumber

" Turn on persistent undo. All undo history will be saved in .vim/undodir
" Put plugins and dictionaries in this dir (also on Windows)
let vimDir = '$HOME/.vim'
let &runtimepath.=','.vimDir

" Keep undo history across sessions by storing it in a file
if has('persistent_undo')
    let myUndoDir = expand(vimDir . '/undodir')
    " Create dirs
    call system('mkdir ' . vimDir)
    call system('mkdir ' . myUndoDir)
    let &undodir = myUndoDir
    set undofile
endif

