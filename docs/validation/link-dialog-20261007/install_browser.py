import pathlib,os,shutil,subprocess
b=pathlib.Path(__file__).resolve().parent/'browser-tools';b.mkdir(exist_ok=True)
s=pathlib.Path('/opt/handrail/repos/handrail/handrail-chat/handrail-sdk-chat-flutter/docs/validation/control-hierarchy-20261007')
for a,z in [('browser-package.json','package.json'),('browser-package-lock.json','package-lock.json')]:shutil.copy2(s/a,b/z)
r=subprocess.run(['npm','ci','--ignore-scripts','--no-audit','--no-fund'],cwd=b);raise SystemExit(r.returncode)
