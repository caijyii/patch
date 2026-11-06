# Extract production HUD widgets for isolated native UI verification.
import re
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
parts = ['import AppKit\n']
for name in ['ToolbarMetrics', 'ToolbarPalette', 'ToolbarMaterialView', 'ToolbarSeparator', 'SelectionButton', 'AnnotationSizeControl', 'SelectionToolbar']:
    match = re.search(r'^(?:final )?(?:class|enum|struct) ' + name + r'\b', source, re.M)
    if not match:
        raise SystemExit('Missing actual shared widget: ' + name)
    start = match.start()
    opening = source.index('{', start)
    depth = 0
    for end in range(opening, len(source)):
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        if depth == 0:
            parts.append(source[start:end + 1] + '\n')
            break
    else:
        raise SystemExit('Incomplete actual shared widget: ' + name)
Path(sys.argv[2]).write_text('\n'.join(parts))
