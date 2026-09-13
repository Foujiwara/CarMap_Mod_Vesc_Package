import fs from 'node:fs';
fs.mkdirSync('.test-runtime', {recursive:true});
let source=fs.readFileSync('tests/vesc-mocks.lisp','utf8');
for(const module of ['util','map','throttle','storage','protocol','package']) {
 let code=fs.readFileSync(`lisp/${module}.lisp`,'utf8');
 if(module==='package') code=code.slice(code.indexOf('(define cfg-preset'),code.lastIndexOf('(if (not (storage-load))'));
 code=code.replace(/;[^\n]*/g,'').replaceAll('\r','');
 source+='\n'+code+'\n';
}
source+=fs.readFileSync('tests/regression.lisp','utf8');
fs.writeFileSync('.test-runtime/regression.lisp',source);
