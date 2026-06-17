complete -c chcon -l reference -d 'Use security context of RFILE, rather than specifying a CONTEXT value.' -r -F
complete -c chcon -s u -l user -d 'Set user USER in the target security context.' -r -f -a "(__fish_complete_users)"
complete -c chcon -s r -l role -d 'Set role ROLE in the target security context.' -r
complete -c chcon -s t -l type -d 'Set type TYPE in the target security context.' -r
complete -c chcon -s l -l range -d 'Set range RANGE in the target security context.' -r
complete -c chcon -l dereference -d 'Affect the referent of each symbolic link (this is the default), rather than the symbolic link itself.'
complete -c chcon -s h -l no-dereference -d 'Affect symbolic links instead of any referenced file.'
complete -c chcon -l help -d 'help'
complete -c chcon -l preserve-root -d 'Fail to operate recursively on \'/\'.'
complete -c chcon -l no-preserve-root -d 'Do not treat \'/\' specially (the default).'
complete -c chcon -s R -l recursive -d 'Operate on files and directories recursively.'
complete -c chcon -s H -d 'If a command line argument is a symbolic link to a directory, traverse it. Only valid when -R is specified.'
complete -c chcon -s L -d 'Traverse every symbolic link to a directory encountered. Only valid when -R is specified.'
complete -c chcon -s P -d 'Do not traverse any symbolic links (default). Only valid when -R is specified.'
complete -c chcon -s v -l verbose -d 'Output a diagnostic for every file processed.'
complete -c chcon -s V -l version -d 'Print version'
