import pathlib,os,shutil,tarfile,json,hashlib
r=pathlib.Path('/opt/handrail/repos/handrail/handrail-chat/handrail-sdk-chat-flutter')
out=pathlib.Path(__file__).resolve().parent;b=pathlib.Path(os.environ['TMPDIR'])/'review';b.mkdir()
fixture=b/'candidate';fixture.mkdir()
with tarfile.open(out.parent/'candidate-sources.tar.gz') as t:t.extractall(fixture)
# Qualified harness retained; only shipped library and canonical metadata updated.
for path in ['lib','test','.handrail']:
 for p in (r/path).rglob('*'):
  if p.is_file():
   d=fixture/p.relative_to(r);d.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,d)
# Keep evidence-only cases registered without changing the repository test parent.
p=fixture/'test/handrail_message_composer_test.dart';s=p.read_text().replace("part 'handrail_link_dialog_cases.dart';", "part 'handrail_link_dialog_cases.dart';\npart 'independent_link_review.dart';").replace('void main() {','void main() {\n  _independentLinkReview();');p.write_text(s)
for path in ['pubspec.yaml','analysis_options.yaml']:shutil.copy2(r/path,fixture/path)
# Rendering asset declaration is fixture-only (same as the qualified browser harness).
p=fixture/'pubspec.yaml';s=p.read_text();s += '\nflutter:\n  uses-material-design: true\n' if '\nflutter:' not in s else '';p.write_text(s)
src=pathlib.Path('/opt/handrail/.handrail/flutter-sdk');f=b/'flutter';(f/'bin/cache').mkdir(parents=True)
for p in src.iterdir():
 if p.name!='bin':(f/p.name).symlink_to(p,target_is_directory=p.is_dir())
for p in (src/'bin').iterdir():
 if p.name!='cache':(f/'bin'/p.name).symlink_to(p,target_is_directory=p.is_dir())
for p in (src/'bin/cache').iterdir():
 if p.name in ['.agents','.aws','.codex','.git','.config','lockfile','pub-cache','.pub-cache','downloads']:continue
 if p.is_dir() or p.suffix=='.snapshot':(f/'bin/cache'/p.name).symlink_to(p,target_is_directory=p.is_dir())
 else:shutil.copy2(p,f/'bin/cache'/p.name)
pc=b/'pub-cache';(pc/'hosted').mkdir(parents=True)
for p in (src/'bin/cache/pub-cache/hosted').iterdir():
 d=pc/'hosted'/p.name;d.mkdir()
 for pkg in p.iterdir():(d/pkg.name).symlink_to(pkg,target_is_directory=pkg.is_dir())
shutil.copytree(src/'bin/cache/pub-cache/hosted-hashes',pc/'hosted-hashes')
(out/'toolchain-reuse.json').write_text(json.dumps({'source':str(src),'adapter':str(f),'binary_copy_count':0,'sdk_download_count':0,'note':'Read-only symlinks reuse installed framework, Dart/engine, compiler snapshot and packages; only mutable Flutter cache metadata/locks are private.'},indent=2)+'\n')
print(b)
