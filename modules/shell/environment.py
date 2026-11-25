"""Closed declaration grammar for typed Shell Capture. Never expand or run input."""
import ast
import re

VARIABLE_KINDS = ('variable', 'path-operation', 'initializer')
KINDS = (*VARIABLE_KINDS, 'setting')
OPTIONS = {'AUTO_CD', 'BEEP', 'HIST_IGNORE_DUPS', 'HIST_IGNORE_SPACE', 'HIST_REDUCE_BLANKS'}
HISTORY = {'HISTSIZE', 'SAVEHIST', 'HISTFILE'}
NAME = r'[A-Za-z_][A-Za-z_0-9]{0,63}'
PRIVATE = re.compile(r'(?i)token|passw(?:or)?d|passwd|secret|credential|api.?key|access.?key|private.?key|session.?id|bearer|authorization|://[^/\s]*@|-----BEGIN|(?:sk-|gh[pousr]_|github_pat_|xox[baprs]-|AKIA|ASIA|eyJ)[A-Za-z0-9_-]{5,}|[a-zA-Z0-9_=-]{28,}')
RESERVED = {'HOME', 'ZDOTDIR', 'IFS', 'ENV', 'BASH_ENV', 'FPATH', 'fpath', 'LD_PRELOAD', 'PS1', 'PROMPT', 'RPS1', 'RANDOM', 'SECONDS', 'commands', 'functions'}
PROVIDERS = {
    'brew shellenv zsh': 'Homebrew', '/opt/homebrew/bin/brew shellenv zsh': 'Homebrew',
    '/usr/local/bin/brew shellenv zsh': 'Homebrew', 'pyenv init - zsh': 'pyenv',
    'pyenv init -': 'pyenv', 'mise activate zsh': 'mise', 'direnv hook zsh': 'direnv',
    'fnm env --use-on-cd --shell zsh': 'fnm', 'fnm env --shell zsh': 'fnm',
    'brew shellenv': 'Homebrew', 'pyenv init --path': 'pyenv',
    '~/.local/bin/mise activate zsh': 'mise', '$HOME/.local/bin/mise activate zsh': 'mise',
}
for launcher in ('mise', '~/.local/bin/mise', '$HOME/.local/bin/mise'):
    for arguments in ('activate zsh --shims', 'activate --shims zsh'):
        PROVIDERS[launcher + ' ' + arguments] = 'mise'
for arguments in ('init - zsh --no-rehash', 'init --no-rehash - zsh', 'init --path --no-rehash'):
    PROVIDERS['pyenv ' + arguments] = 'pyenv'
SOURCED = {'"$NVM_DIR/nvm.sh"': 'nvm', '"$HOME/.cargo/env"': 'Cargo', '"$HOME/.asdf/asdf.sh"': 'asdf'}
NVM_DIRECTORY = 'export NVM_DIR="$([ -z "${XDG_CONFIG_HOME-}" ] && printf %s "${HOME}/.nvm" || printf %s "${XDG_CONFIG_HOME}/nvm")"'
FRAMEWORK_PARAMETERS = {'plugins', 'ZSH_THEME', 'VIRTUAL_ENV'}
# Zsh special parameters with shell-owned arithmetic, state, display or lookup
# semantics. Locale preferences and the separately typed PATH interfaces remain portable.
SHELL_PARAMETERS = set('''ERRNO GID EGID HISTSIZE RANDOM SAVEHIST SECONDS UID EUID TTYIDLE USERNAME
histchars TERM TERMINFO TERMINFO_DIRS WORDCHARS IFS _ KEYBOARD_HACK HISTCMD LINENO PPID
ZSH_SUBSHELL COLUMNS LINES ZLE_RPROMPT_INDENT SHLVL FUNCNEST OPTIND TRY_BLOCK_ERROR
TRY_BLOCK_INTERRUPT OPTARG NULLCMD POSTEDIT READNULLCMD PS1 RPS1 RPROMPT PS2 RPS2
RPROMPT2 PS3 PS4 SPROMPT CDPATH FIGNORE FPATH MAILPATH PSVAR ZSH_EVAL_CONTEXT
MODULE_PATH ARGC HISTCHARS status prompt PROMPT PROMPT2 PROMPT3 PROMPT4 MANPATH argv
fignore cdpath fpath mailpath manpath psvar zsh_eval_context module_path pipestatus'''.split())
KNOWN = {'EDITOR': 'Preferred text editor', 'VISUAL': 'Preferred visual editor',
         'LANG': 'Language and locale', 'GOPATH': 'Go workspace', 'GOBIN': 'Go command directory',
         'CARGO_HOME': 'Cargo directory', 'PYENV_ROOT': 'pyenv directory', 'NVM_DIR': 'Node version manager directory'}


class Excluded(ValueError):
    """Fixed codes only. Never attach source text to diagnostics."""


def control_parameter(name):
    """Bindings with executable, framework, prompt or special Zsh ownership."""
    return (shell_control_parameter(name) or name in FRAMEWORK_PARAMETERS or
            name in {'ZSH', 'RUBYOPT', 'PERL5OPT', 'PYTHONSTARTUP', 'NODE_OPTIONS', 'GIT_SSH_COMMAND'})


def shell_control_parameter(name):
    # Framework-owned inputs can share a reserved prefix. Their consumers
    # are still runtime boundaries in control_parameter().
    if name in FRAMEWORK_PARAMETERS:
        return False
    return (name in SHELL_PARAMETERS or name in (RESERVED - {'HOME'}) or
            name in {'ENV', 'module_path', 'MODULE_PATH', 'functions_source', 'options',
                     'aliases', 'galiases', 'saliases', 'parameters', 'builtins', 'dis_functions',
                     'termcap', 'terminfo', 'history', 'HISTFILE', 'histchars', 'PS4', 'PS2',
                     'PS3', 'RPROMPT', 'SPROMPT', 'RPS2', 'PROMPT2', 'PROMPT3', 'PROMPT4',
                     'PERIOD', 'TMOUT', 'ZLE_RPROMPT_INDENT', 'WATCH', 'watch', 'cdpath',
                     'CDPATH', 'FPATH', 'MAILPATH', 'mailpath', 'MANPATH', 'manpath'} or
            name.endswith('_functions') or name.startswith(('DYLD_', 'LD_', 'ZSH_', 'PROMPT_', 'TRAP')))


def static_integer(expression):
    """Bounded signed decimal arithmetic without names, substitution or side effects."""
    if not isinstance(expression, str) or len(expression) > 64 or not re.fullmatch(
            r'[0-9()+* -]+', expression) or re.search(r'\+\+|--|\*\*|(?<![0-9])0[0-9]', expression):
        return False
    def number(node):
        if isinstance(node, ast.Constant) and type(node.value) is int:
            value = node.value
        elif isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            value = number(node.operand) * (-1 if isinstance(node.op, ast.USub) else 1)
        elif isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Sub, ast.Mult)):
            a, b = number(node.left), number(node.right)
            value = a + b if isinstance(node.op, ast.Add) else a - b if isinstance(node.op, ast.Sub) else a * b
        else:
            raise ValueError()
        if not -(2 ** 31) <= value < 2 ** 31:
            raise ValueError()
        return value
    try:
        number(ast.parse(expression.strip(), mode='eval').body)
        return True
    except (ValueError, SyntaxError):
        return False


def words(text, array):
    """Split only at unquoted array whitespace. Preserve literal/reference boundaries."""
    result, word, literal, quote = [], [], [], ''
    index, started = 0, False

    def flush():
        if literal:
            value = ''.join(literal)
            if PRIVATE.search(value):
                raise Excluded('restricted_content')
            word.append(['literal', value])
            literal.clear()

    while index < len(text):
        char = text[index]
        index += 1
        if not quote and char in ' \t\r\n':
            if not array:
                raise Excluded('compound_command')
            if started:
                flush()
                result.append(word)
                word, started = [], False
            continue
        word_start = not started
        started = True
        if char == quote:
            quote = ''
        elif not quote and char in "'\"":
            quote = char
        elif char == '\\' and quote != "'":
            if index == len(text):
                raise Excluded('unsupported_escape')
            escaped = text[index]
            index += 1
            if quote and escaped not in '$\\"\\\n`':
                literal.append('\\')
            if escaped != '\n':
                literal.append(escaped)
        elif char == '~' and not quote and word_start and text[index:index + 1] == '/':
            word.append(['home', 'HOME'])
        elif char == '$' and quote != "'":
            default = re.match(r'\{(' + NAME + r')(:-|-)(\$HOME/[A-Za-z0-9_./-]{1,96})\}', text[index:])
            if default and quote == '"':
                if PRIVATE.search(default[1]) or PRIVATE.search(default[3]) or '..' in default[3].split('/'):
                    raise Excluded('restricted_content')
                flush()
                word.append(['home-default', default[1], default[2], default[3][5:]])
                index += default.end()
                continue
            match = re.match(r'\{(' + NAME + r')(?:(:-|-|:\+|\+)([A-Za-z0-9_./ -]{0,128}))?\}|(' + NAME + ')', text[index:])
            if not match:
                raise Excluded('dynamic_expression')
            # Unbraced Zsh parameters can consume a following subscript or
            # colon modifier even inside double quotes.
            if match[4] and re.match(r'\[|:[A-Za-z&]', text[index + match.end():]):
                raise Excluded('dynamic_expression')
            flush()
            name = match[1] or match[4]
            if PRIVATE.search(name) or (match[3] and PRIVATE.search(match[3])):
                raise Excluded('restricted_content')
            word.append(['reference', name, match[2], match[3], 'quoted' if quote else 'bare'])
            index += match.end()
        elif ((not quote and char in '|;&<>(){}[]*?~#=!') or
              (quote != "'" and char in '`!') or ord(char) < 32 and char not in '\t\n'):
            raise Excluded('dynamic_expression')
        else:
            literal.append(char)
    if quote:
        raise Excluded('incomplete_word')
    if started or not array:
        flush()
        result.append(word)
    if len(result) > 256 or sum(map(len, result)) > 512:
        raise Excluded('resource_limit')
    return result


def path_sequence(name, operator, array, values):
    """Separate colon fields only on the scalar interface. Empty fields survive."""
    if not operator:
        return dict(action='attribute', components=[])
    if array:
        components = values
    else:
        components = [[]]
        for part in values[0]:
            if part[0] != 'literal':
                components[-1].append(part)
                continue
            for i, segment in enumerate(part[1].split(':')):
                if i:
                    components.append([])
                if segment:
                    components[-1].append(['literal', segment])
    if len(components) > 256:
        raise Excluded('resource_limit')
    splices = [i for i, parts in enumerate(components) if len(parts) == 1 and parts[0][0] == 'reference'
               and parts[0][1] == name and parts[0][2] is None and (not array or parts[0][4] == 'bare')]
    if operator == '+=':
        action = 'append-elements' if array else 'concatenate-scalar'
    elif not splices:
        action = 'assign-expression' if any(p[0] == 'reference' and p[1] == name for w in components for p in w) else 'replace'
    elif len(components) == 1:
        action = 'retain-expression'
    elif splices == [0]:
        action = 'suffix'
    elif splices == [len(components) - 1]:
        action = 'prefix'
    else:
        action = 'ordered-splices'
    return dict(action=action, components=components)


def declaration_operands(text):
    """Find operand boundaries only. Each resulting complete word is re-admitted."""
    chunks, start, quote, escaped, nesting = [], None, '', False, 0
    for i, char in enumerate(text):
        if char in ' \t' and not (quote or escaped or nesting):
            if start is not None:
                chunks.append(text[start:i])
                start = None
            continue
        if start is None:
            start = i
        if escaped:
            escaped = False
        elif char == '\\' and quote != "'":
            escaped = True
        elif char == quote:
            quote = ''
        elif not quote and char in "'\"":
            quote = char
        elif not quote and char == '(':
            nesting += 1
        elif not quote and char == ')':
            nesting -= 1
    if start is not None:
        chunks.append(text[start:])
    return chunks


def setting_parameters(writes, reads):
    """Separate lexical Setting dependencies from shell-owned control state."""
    structural = (SHELL_PARAMETERS | RESERVED | {'options', 'aliases', 'galiases', 'saliases',
                  'parameters', 'builtins', 'dis_functions', 'functions_source'}) - HISTORY
    if writes & structural or any(n.endswith('_functions') or n.startswith(('TRAP', 'LD_', 'DYLD_')) for n in writes):
        return 'unknown', set()
    if any(control_parameter(n) for n in writes - HISTORY):
        # These bindings may influence external initialization. No dependency
        # on a particular tool or interpretation of its configuration is assumed.
        return 'runtime', (writes | reads) & HISTORY
    return 'dependency', (writes | reads) & HISTORY


def setting_invocation_commands(text):
    """Command lookups in a literal external initialization boundary."""
    argv = r'([A-Za-z0-9_./-]+)(?:[ \t]+[A-Za-z0-9_./-]+)*'
    call = (re.fullmatch(r'(eval) "\$\(' + argv + r'\)"', text) or
            re.fullmatch(r'(source|\.)[ \t]+<\(' + argv + r'\)', text))
    return set(call.groups()) if call else set()


def setting_source_operand(text):
    symbolic = re.fullmatch(r'(?:source|\.)[ \t]+"\$(' + NAME + r')((?:/[A-Za-z0-9_.-]+)+)"', text)
    if symbolic and symbolic[1] not in ('HOME', 'ZDOTDIR'):
        parts = symbolic[2][1:].split('/')
        if not {'.', '..'}.intersection(parts) and parts[-1] not in ('.zshenv', '.zprofile', '.zshrc', '.zlogin'):
            return symbolic[1], symbolic[2][1:]
    return None


def setting_literal_binding(text):
    literal = re.fullmatch(r'(?:export[ \t]+)?(' + NAME + r')="[A-Za-z0-9_./-]*"', text)
    return literal[1] if literal else None


def setting_context(raw):
    """Private effects of a parser-bounded, non-selectable statement.

    A runtime boundary describes where unknown output occurs. It conveys no
    trust in the executable, its output, or the contents of an external script.
    """
    if len(raw) > 4096:
        return 'unknown', set()
    text = raw.decode()
    option = re.fullmatch(r'(?:setopt|unsetopt)[ \t]+([A-Za-z_]+)', text)
    if option:
        name = option[1].upper().replace('_', '').removeprefix('NO')
        for key in OPTIONS | {'INTERACTIVE_COMMENTS'}:
            if name == key.replace('_', ''):
                return 'dependency', {key}
    if re.fullmatch(r"""bindkey[ \t]+(?:"[\w^ -]+"|'[\w^ -]+')[ \t]+[a-z][a-z0-9-]*""", text):
        return 'dependency', {'KEYMAP'}
    # The B5 grammar can identify exact reads and writes even when a history
    # interaction excludes a declaration from the selectable B5 inventory.
    try:
        kind, name, intent = classify_declaration(text)
    except Excluded:
        pass
    else:
        if kind != 'initializer':
            writes, reads = parameter_uses(name, intent)
            if (writes | reads) & HISTORY:
                return setting_parameters(writes, reads)
    literal = setting_literal_binding(text)
    if literal:
        return setting_parameters({literal}, set())
    if setting_invocation_commands(text):
        return 'runtime', set()
    if setting_source_operand(text):
        return 'runtime', set()
    return 'unknown', set()


def classify_setting(text):
    option = re.fullmatch(r'(setopt|unsetopt)[ \t]+([A-Z_]+)', text)
    if option and option[2] in OPTIONS:
        return 'setting', option[2], dict(group='options', value=option[1] == 'setopt', guard=None)
    number = re.fullmatch(r'(HISTSIZE|SAVEHIST)=([1-9][0-9]{0,5}|1000000)', text)
    if number:
        return 'setting', number[1], dict(group='history', value=int(number[2]), guard=None)
    history = re.fullmatch(r'HISTFILE="(?:\$HOME|\$\{HOME\})/(\.zsh_history|\.zhistory)"', text)
    if history:
        return 'setting', 'HISTFILE', dict(group='history', value=history[1], guard=None)
    keymap = re.fullmatch(r'bindkey[ \t]+-(e|v)', text)
    if keymap:
        return 'setting', 'KEYMAP', dict(group='keymaps', value='emacs' if keymap[1] == 'e' else 'vi', guard=None)
    return None


def classify(text, *, settings=False):
    """Return (kind, binding, intent) for one complete parser-bounded outer sublist."""
    if len(text.encode()) > 4096:
        raise Excluded('resource_limit')
    if PRIVATE.search(text):
        raise Excluded('restricted_content')
    if settings:
        setting = classify_setting(text)
        if setting:
            return setting
    kind, name, intent = classify_declaration(text)
    if settings and kind != 'initializer':
        writes, reads = parameter_uses(name, intent)
        if (writes | reads) & HISTORY:
            raise Excluded('special_parameter')
    return kind, name, intent


def classify_declaration(text):
    guard = None
    guarded = re.fullmatch(r'\[\[ -o (interactive|login) \]\][ \t]+&&[ \t]+(.+)', text, re.S)
    if guarded:
        guard, text = guarded.groups()
    else:
        guarded = re.fullmatch(r'if[ \t]+\[\[ -o (interactive|login) \]\];[ \t]*then[ \t\n]+(.+?);[ \t\n]*fi', text, re.S)
        if guarded:
            guard, text = guarded.groups()
    if guard is None:
        conditional_source = re.fullmatch(r'(?:\[\[ -s "\$NVM_DIR/nvm\.sh" \]\]|\[ -s "\$NVM_DIR/nvm\.sh" \])[ \t]+&&[ \t]+(?:source|\\?\.)[ \t]+("\$NVM_DIR/nvm\.sh"(?: --no-use)?)', text)
        if conditional_source:
            guard, text = 'nonempty-nvm-script', 'source ' + conditional_source[1]
        elif text == '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"':
            guard, text = 'pyenv-bin-directory', 'export PATH="$PYENV_ROOT/bin:$PATH"'
    if text == NVM_DIRECTORY:
        return 'variable', 'NVM_DIR', dict(form='export', flags='', operator='=', array=False,
            guard=guard, words=[[['nvm-directory', 'XDG_CONFIG_HOME', 'HOME']]])
    # A declaration builtin with multiple operands is one indivisible selection.
    # Reject the entire group when any operand fails admission.
    group = re.fullmatch(r'(export|typeset|integer|readonly)([ \t]+-[gxriaAU]+)?[ \t]+(.+)', text, re.S)
    if group:
        operands = declaration_operands(group[3])
        if group[1] == 'typeset' and (group[2] or '').strip() == '-U' and operands in (['path', 'PATH'], ['PATH', 'path']):
            return 'path-operation', operands[0], dict(form='typeset', flags='U', operator=None, words=[], array=False,
                guard=guard, interfaces=operands, path=dict(action='attribute', components=[]))
        if len(operands) > 1:
            if len(operands) > 32:
                raise Excluded('resource_limit')
            members = []
            prefix = group[1] + (group[2] or '') + ' '
            for operand in operands:
                if not re.match(NAME, operand):
                    raise Excluded('unsupported_declaration')
                kind, key, intent = classify(prefix + operand)
                if kind != 'variable':
                    raise Excluded('mixed_parameter_group')
                members.append(dict(name=key, declaration=intent))
            return 'variable', members[0]['name'], dict(guard=guard, members=members)
    invocation = re.fullmatch(r'eval "\$\(([^()"]+)\)"', text)
    quoted_mise = re.fullmatch(r'eval "\$\("\$(?:HOME|\{HOME\})/\.local/bin/mise" (activate (?:zsh(?: --shims)?|--shims zsh))\)"', text)
    if quoted_mise:
        return 'initializer', 'mise', dict(provider='mise', variant='~/.local/bin/mise ' + quoted_mise[1], guard=guard)
    sourcing = re.fullmatch(r'(?:source|\.) (.+)', text)
    provider = PROVIDERS.get(invocation[1]) if invocation else SOURCED.get(sourcing[1]) if sourcing else None
    if invocation and provider is None:
        absolute = re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/){1,10}bin/([a-z0-9-]+ .+)', invocation[1])
        if absolute and '..' not in invocation[1].split('/'):
            provider = PROVIDERS.get(absolute[1])
    if provider:
        return 'initializer', provider, dict(provider=provider, variant=invocation[1] if invocation else sourcing[1], guard=guard)
    if sourcing and sourcing[1] == '"$NVM_DIR/nvm.sh" --no-use':
        return 'initializer', 'nvm', dict(provider='nvm', variant=sourcing[1], guard=guard)
    if invocation and re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/){1,8}bin/brew shellenv(?: zsh)?', invocation[1]) and '..' not in invocation[1].split('/'):
        return 'initializer', 'Homebrew', dict(provider='Homebrew', variant=invocation[1], guard=guard)
    if invocation or text.startswith(('eval ', 'source ', '. ')):
        raise Excluded('external_initializer')
    match = re.fullmatch(r'(?:(export|typeset|integer|readonly|unset)[ \t]+(?:(-[gxriaAU]+)[ \t]+)?)?(' + NAME + r')(?:(\+?=)(.*))?', text, re.S)
    if not match:
        raise Excluded('unsupported_declaration')
    form, flags, name, op, operand = match.groups()
    flags = (flags or '').lstrip('-')
    if name in RESERVED or name.startswith(('DYLD_', 'LD_', 'ZSH_', 'PROMPT_')):
        raise Excluded('special_parameter')
    if (not op and not form or flags and form != 'typeset' or len(set(flags)) != len(flags)
            or form == 'unset' and op or 'A' in flags and 'a' in flags):
        raise Excluded('unsupported_declaration')
    if (name in ('PATH', 'path') and (form in ('integer', 'unset', 'readonly') or
            any(flag not in ('gxU' if name == 'PATH' else 'gaU') for flag in flags))):
        raise Excluded('unsupported_attributes')
    array = operand is not None and operand.startswith('(') and operand.endswith(')')
    if array and (name == 'PATH' or form in ('export', 'integer') or 'i' in flags or 'x' in flags):
        raise Excluded('unsupported_attributes')
    if op and (('A' in flags or 'a' in flags or name == 'path') and not array):
        raise Excluded('unsupported_attributes')
    values = words(operand[1:-1] if array else operand, array) if op else []
    if 'A' in flags and (len(values) % 2 or any(not k or any(p[0] != 'literal' for p in k) for k in values[::2])):
        raise Excluded('unsupported_association')
    if (form == 'integer' or 'i' in flags) and op and not (len(values) == 1 and len(values[0]) == 1 and
            values[0][0][0] == 'literal' and static_integer(values[0][0][1])):
        raise Excluded('computed_integer')
    intent = dict(form=form or 'assignment', flags=flags, operator=op, words=values, array=array, guard=guard)
    if name in ('PATH', 'path'):
        intent['path'] = path_sequence(name, op, array, values)
        return 'path-operation', name, intent
    return 'variable', name, intent


def parameter_uses(name, intent):
    if 'group' in intent:
        if intent['group'] == 'history':
            return {name}, {'HOME'} if name == 'HISTFILE' else set()
        return {'setting:' + name}, set()
    if 'provider' in intent:
        # Only the source operand is lexical input. A provider's runtime effects
        # and the contents of its script remain unknown.
        if intent['provider'] == 'nvm':
            return set(), {'NVM_DIR'}
        return set(), {'HOME'} if intent['variant'] in SOURCED else set()
    members = intent.get('members', [dict(name=name, declaration=intent)])
    writes, reads = set(), set()
    for member in members:
        declaration = member['declaration']
        references = {part[1] for word in declaration['words'] for part in word if part[0] == 'reference'}
        for word in declaration['words']:
            for part in word:
                if part[0] in ('home-default', 'nvm-directory'):
                    references.update(('HOME', part[1]))
        if declaration['operator'] == '+=' or (declaration['operator'] is None and declaration['form'] != 'unset'):
            references.add(member['name'])
        if references & {'PATH', 'path'}:
            references.update(('PATH', 'path'))
        reads.update(references - writes)
        writes.add(member['name'])
        if member['name'] in ('PATH', 'path'):
            writes.update(('PATH', 'path'))
    return writes, reads


def presentation(row, contexts, source):
    kind, name, ir = row['kind'], row['key'], row['details']['intent']
    if kind == 'setting':
        if ir['group'] == 'options':
            label = name + (' — Enabled' if ir['value'] else ' — Disabled')
            detail = 'Preserves the saved Zsh option in its startup context.'
        elif ir['group'] == 'history':
            label = name + ' — ' + ('~/' if name == 'HISTFILE' else '') + str(ir['value'])
            detail = 'Restores the history setting. Command history is never transferred.'
        else:
            label = 'Keymap — ' + ('Emacs' if ir['value'] == 'emacs' else 'Vi')
            detail = 'Selects the standard editing keymap for interactive Zsh sessions.'
    elif kind == 'initializer':
        label = name + ' — Initialize shell environment'
        detail = 'Configures ' + name + ' for new shell sessions. It must be available on the destination Mac.'
        if name == 'nvm' and not ir['variant'].endswith(' --no-use'):
            detail = 'Saves automatic Node activation. Rebuild cannot yet qualify its project and executable dependencies.'
    elif kind == 'variable':
        label = name + ' — ' + KNOWN.get(name, 'Custom shell variable')
        if 'members' in ir:
            label = name + ' — Group of ' + str(len(ir['members'])) + ' shell declarations'
        detail = ('Sets the editor used by command-line tools that support this setting.' if name in ('EDITOR', 'VISUAL')
                  else 'Saves this variable declaration, including its value when one is assigned.')
        if ir.get('form') == 'unset':
            detail = 'Removes this variable when the declaration runs.'
        elif 'members' not in ir and ir['operator'] is None:
            detail = ('Makes this variable available to processes started by the shell.' if ir['form'] == 'export' or 'x' in ir['flags']
                      else 'Declares this variable or changes its attributes without assigning a value.')
        if 'members' in ir:
            detail = 'Saves all variables in this declaration together to preserve their order.'
        changes, reads = parameter_uses(name, ir)
        if any(control_parameter(binding) for binding in changes | reads):
            detail = 'This setting has shell-owned behavior. Rebuild cannot qualify it as an ordinary variable.'
    else:
        parts = ir['words']
        action = 'Change command search path'
        detail = 'Preserves this operation and the order of its directories.'
        if 'U' in ir['flags'] and not ir['operator']:
            action, detail = 'Keep unique directories', 'Repeated directories may be removed when the shell applies this attribute.'
        elif ir['operator'] == '+=':
            action = 'Add directories last' if ir['array'] else 'Extend search path text'
        elif ir['operator']:
            if ir['path']['action'] == 'replace':
                action, detail = 'Replace command search path', 'Replaces the previous search path. This can change which commands are found.'
            elif len(parts) == 1:
                # Expose only well-known portable bin directories, never arbitrary private values.
                segments = [(p[0], p[1]) if p[0] != 'reference' or p[2] is None else ('default', p[1]) for p in parts[0]]
                for folder in ('/.local/bin', '/bin', '/.cargo/bin'):
                    if segments == [('reference', 'HOME'), ('literal', folder + ':'), ('reference', 'PATH')]:
                        action = 'Add ~' + folder + ' first'
                    elif segments == [('reference', 'PATH'), ('literal', ':'), ('reference', 'HOME'), ('literal', folder)]:
                        action = 'Add ~' + folder + ' last'
        if action == 'Change command search path':
            action = {'prefix': 'Add directories first', 'suffix': 'Add directories last'}.get(ir['path']['action'], action)
        if ir['path']['action'] == 'prefix':
            detail = 'Searches the added directories before the existing command search path.'
        elif ir['path']['action'] in ('suffix', 'append-elements'):
            detail = 'Searches the added directories after the existing command search path.'
        if 'U' in ir['flags'] and ir['operator']:
            detail += ' It also keeps only the first occurrence of each directory.'
        label = 'PATH — ' + action
    scope = ('Login shells' if contexts == {'login', 'interactive-login'} else
             'Interactive shells' if contexts == {'interactive', 'interactive-login'} else 'Applicable shell sessions')
    if ir['guard']:
        scope += {'nonempty-nvm-script': ' · if nvm is available', 'pyenv-bin-directory': ' · if bin exists', 'interactive': ' · when interactive',
                  'login': ' · at login'}[ir['guard']]
    origin = source if source in ('.zshenv', '.zprofile', '.zshrc', '.zlogin') else 'a sourced configuration file'
    result = dict(label=label, explanation=detail, context=scope, origin=origin, capture_only=False)
    if kind == 'setting':
        result['setting_group'] = ir['group']
    return result


def requirement_details(snapshot):
    loads = {r['id']: r['context'] for r in snapshot._value['loads']}
    sources = {r['id']: r['path'] for r in snapshot._value['sources']}
    startup_names = {'.zshenv': 'the Zsh environment file', '.zprofile': 'the Zsh login profile',
                     '.zshrc': 'the interactive Zsh startup file', '.zlogin': 'the Zsh login file'}
    details = {}
    for row in snapshot._value['items']:
        if row['kind'] in KINDS:
            intent = row['details']['intent']
            info = presentation(row, {loads[k] for k in row['loads']}, sources[row['source']])
            info['origin'] = startup_names.get(info['origin'], info['origin'])
            if row['kind'] == 'path-operation' and 'U' in intent['flags'] and intent['operator']:
                info['label'] += ' (unique directories)'
            details[row['id']] = info
    return details


def requirement_labels(snapshot):
    return {key: info['label'] for key, info in requirement_details(snapshot).items()}


def scope_explanations(codes):
    return ['Some Shell configuration could not be captured.'] if codes else []


def legacy_safe(raw):
    """Whole-file fallback has no item consent. Admit only public preference values."""
    try:
        text = raw.decode()
        if PRIVATE.search('\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('#'))):
            return False
        for line in text.splitlines():
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            if not re.fullmatch(r'(?:export[ \t]+)?(?:EDITOR|VISUAL)=(?:vim|vi|nvim|nano|emacs|code)|(?:export[ \t]+)?LANG=(?:C|[a-z]{2}_[A-Z]{2}\.UTF-8)|(?:un)?setopt [A-Za-z_]+', line.strip()):
                return False
        return all(not PRIVATE.search(line) for line in text.splitlines() if line.lstrip().startswith('#'))
    except UnicodeError:
        return False


if __name__ == '__main__':
    import sys
    try:
        with open(sys.argv[1], 'rb') as stream:
            allowed = legacy_safe(stream.read(65537))
    except OSError:
        raise SystemExit(2) from None
    raise SystemExit(0 if allowed else 1)
