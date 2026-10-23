#!/usr/bin/env python3
"""Copie dans <app>/Contents/Frameworks toutes les bibliothèques Homebrew (et @rpath) dont dépendent
les binaires donnés, réécrit leurs chemins en @rpath/<nom> et retire les rpaths absolus de la machine
de construction : l'app tourne alors sur un Mac sans Homebrew.

Usage : bundle-dylibs.py <Frameworks> <binaire ou dylib>... [--search <dossier>]...
"""
import os, shutil, subprocess, sys

def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout

def deps(path):
    return [l.strip().split(' (')[0] for l in run('otool', '-L', path).splitlines()[1:]]

def rpaths(path):
    lines = run('otool', '-l', path).splitlines()
    # "path /some dir/with spaces (offset 12)"
    return [lines[i + 2].strip()[len('path '):].rsplit(' (offset', 1)[0] for i, l in enumerate(lines) if 'LC_RPATH' in l]

def is_system(dep):
    return dep.startswith(('/usr/lib/', '/System/')) or dep.startswith('@executable_path/../Frameworks/Chromium')

def resolve(dep, owner, search):
    """Absolute path of a dependency, or None when it cannot be found"""
    if dep.startswith('@rpath/'):
        name = dep[len('@rpath/'):]
        for base in rpaths(owner) + search:
            base = base.replace('@loader_path', os.path.dirname(owner))
            if os.path.exists(os.path.join(base, name)):
                return os.path.realpath(os.path.join(base, name))
        return None
    return os.path.realpath(dep) if dep.startswith('/') else None

def main():
    args = sys.argv[1:]
    search = [args[i + 1] for i, a in enumerate(args) if a == '--search']
    args = [a for i, a in enumerate(args) if a != '--search' and (i == 0 or args[i - 1] != '--search')]
    frameworks, roots = args[0], args[1:]
    os.makedirs(frameworks, exist_ok=True)
    todo, done = list(roots), set()
    while todo:
        path = todo.pop()
        if path in done:
            continue
        done.add(path)
        os.chmod(path, 0o755)
        for dep in deps(path):
            if is_system(dep) or dep.startswith(('@executable_path', '@loader_path')):
                continue
            name = os.path.basename(dep)
            target = os.path.join(frameworks, name)
            if not os.path.exists(target):
                source = resolve(dep, path, search)
                if source is None:
                    sys.exit(f'introuvable : {dep} (requis par {path})')
                shutil.copy2(source, target)
                os.chmod(target, 0o755)
                run('install_name_tool', '-id', f'@rpath/{name}', target)
            todo.append(target)
            if dep != f'@rpath/{name}':
                run('install_name_tool', '-change', dep, f'@rpath/{name}', path)
        # only the bundle is searched: never the build machine
        for rp in rpaths(path):
            if rp.startswith('/'):
                run('install_name_tool', '-delete_rpath', rp, path)
        wanted = '@loader_path' if os.path.dirname(path) == frameworks else '@executable_path/../Frameworks'
        if wanted not in rpaths(path):
            run('install_name_tool', '-add_rpath', wanted, path)
    leaks = [f'{p}: {d}' for p in done for d in deps(p) if d.startswith(('/opt/', '/usr/local/', os.path.expanduser('~')))]
    if leaks:
        sys.exit('chemins hors du bundle :\n' + '\n'.join(leaks))
    print(f'{len(done)} binaires, {len(os.listdir(frameworks))} éléments dans Frameworks')

main()
