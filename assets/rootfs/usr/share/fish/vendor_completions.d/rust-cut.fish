complete -c cut -s b -l bytes -d 'filter byte columns from the input source' -r
complete -c cut -s c -l characters -d 'alias for character mode' -r
complete -c cut -s d -l delimiter -d 'specify the delimiter character that separates fields in the input source. Defaults to Tab.' -r
complete -c cut -s f -l fields -d 'filter field columns from the input source' -r
complete -c cut -l output-delimiter -d 'in field mode, replace the delimiter in output lines with this option\'s argument' -r
complete -c cut -s w -d 'Use any number of whitespace (Space, Tab) to separate fields in the input source (FreeBSD extension).'
complete -c cut -l complement -d 'invert the filter - instead of displaying only the filtered columns, display all but those columns'
complete -c cut -s s -l only-delimited -d 'in field mode, only print lines which contain the delimiter'
complete -c cut -s z -l zero-terminated -d 'instead of filtering columns based on line, filter columns based on \\\\0 (NULL character)'
complete -c cut -s n -d '(ignored)'
complete -c cut -s h -l help -d 'Print help'
complete -c cut -s V -l version -d 'Print version'
