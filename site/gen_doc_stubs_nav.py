# Generate virtual doc files for the mkdocs site.
# You can also run this script directly to actually write out those files, as a preview.

import mkdocs_gen_files

# Get the documentation root object
root = mkdocs_gen_files.config['plugins']['mkdocstrings'].get_handler('crystal').collector.root

# Start a navigation file (to be filled as we go along)
nav = mkdocs_gen_files.open('SUMMARY.md', 'a')

# For each type (e.g. "Foo::Bar")
for typ in root.walk_types():
    # Use the file name "Foo/Bar.md"
    filename = '/'.join(typ.abs_id.split('::')) + '.md'
    # Make a file with the content "::: Foo::Bar\n"
    with mkdocs_gen_files.open(filename, 'w') as f:
        print(f'::: {typ.abs_id}', file=f)

    # Append to the nav: "    * [Bar](Foo/Bar.md)"
    indent = '    ' * typ.abs_id.count('::')
    print(indent + f'* [{typ.name}]({filename})', file=nav)
