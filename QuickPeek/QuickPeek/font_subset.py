"""Export a validated Unicode subset without touching the source font."""
import json, os, sys, tempfile
from pathlib import Path
from fontTools import subset
from fontTools.ttLib import TTFont

def export(source, destination, text):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('不能覆盖原字体，请选择新的文件名。')
    with TTFont(source, recalcTimestamp=False) as font:
        requested = {ord(c) for c in text if not c.isspace() or c == ' '}
        original = font.getBestCmap() or {}
        expected = requested & set(original)
        if not expected:
            raise ValueError('该字体不包含选定的字符。')
        options = subset.Options()
        options.name_IDs = ['*']; options.name_languages = ['*']; options.name_legacy = True
        options.glyph_names = True; options.notdef_outline = True
        options.layout_features = ['*']
        worker = subset.Subsetter(options=options)
        worker.populate(unicodes=expected); worker.subset(font)
        # Give the subset its own identity so it cannot shadow the original font.
        names = font['name']
        for record in names.names:
            if record.nameID in (1, 3, 4, 6, 16):
                value = record.toUnicode() + ('-Subset' if record.nameID == 6 else ' Subset')
                record.string = value.encode(record.getEncoding(), errors='replace')
        if 'DSIG' in font: del font['DSIG']
        fd, temporary = tempfile.mkstemp(prefix='.QuickPeek-font-',suffix=destination.suffix,dir=destination.parent)
        os.close(fd)
        try:
            font.save(temporary)
            with TTFont(temporary) as verified:
                if set(verified.getBestCmap() or {}) != expected:
                    raise ValueError('字符映射校验失败，未保存输出。')
            os.replace(temporary,destination)
        finally:
            if os.path.exists(temporary): os.unlink(temporary)
    return {'kept':len(expected),'missing':len(requested-expected),'bytes':destination.stat().st_size}

if __name__ == '__main__':
    try:
        print(json.dumps(export(sys.argv[1],sys.argv[2],Path(sys.argv[3]).read_text(encoding='utf-8')),ensure_ascii=False))
    except Exception as exc:
        print(str(exc),file=sys.stderr);sys.exit(1)
