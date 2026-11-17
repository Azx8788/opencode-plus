import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/builtin/insights/insights_core_js.dart';
import 'package:opencode_mobile/builtin/insights/insights_plugin_js.dart';

void main() {
  test(
    'generated event collector is bounded, idempotent and excludes secrets',
    () async {
      final directory = await Directory.systemTemp.createTemp('plus-insights-');
      addTearDown(() => directory.delete(recursive: true));
      final core = File('${directory.path}/core.mjs');
      await core.writeAsString(insightsCoreJs);
      final test = File('${directory.path}/test.mjs');
      await test.writeAsString(r'''
import { append,project } from './core.mjs';
import assert from 'node:assert/strict';
const event={id:'e1',created:1000,type:'session.step.started',data:{sessionID:'s',assistantMessageID:'a',
  model:{providerID:'p',id:'m'},text:'SECRET',input:{token:'SECRET'},tokens:{input:10,secret:'SECRET'}}};
let snapshot={version:1,seq:0,entries:[],truncated:false};
snapshot=append(snapshot,event,2);
assert.equal(snapshot.entries.length,1);
assert.equal(append(snapshot,event,2),snapshot);
assert.ok(!JSON.stringify(snapshot).includes('SECRET'));
assert.equal(project({...event,type:'session.text.delta'}),null);
const missing=project({...event,id:'e2',created:undefined});
assert.ok(!('at' in missing));
snapshot=append(snapshot,{...event,id:'e2'},2);
snapshot=append(snapshot,{...event,id:'e3'},2);
assert.equal(snapshot.entries.length,2);assert.equal(snapshot.truncated,true);
''');
      final result = await Process.run('node', [test.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
  );

  test('fixed search selection requires authorization and never falls back', () async {
    final directory = await Directory.systemTemp.createTemp('plus-search-');
    addTearDown(() => directory.delete(recursive: true));
    final plugin = insightsPluginJs.replaceAll(
      RegExp(r'^import .*;\s*$', multiLine: true),
      '',
    );
    await File('${directory.path}/plugin.mjs').writeAsString(
      'const Plugin={define:v=>v};const Insights={};const append=()=>null;\n$plugin',
    );
    final file = File('${directory.path}/test.mjs');
    await file.writeAsString(r'''
import plugin from './plugin.mjs';
import assert from 'node:assert/strict';
let handlers,transform,selected,authorized=false;
const values=new Map();
const editor={default:{set:v=>selected=v,get:()=>selected}};
const ctx={storage:{get:async k=>values.get(k),set:async(k,v)=>values.set(k,v)},
  websearch:{transform:async f=>{transform=f;f(editor)},reload:async()=>transform(editor),providers:async()=>[{id:'tavily',name:'Tavily'}]},
  integration:{connection:{active:async()=>authorized ? {type:'credential'} : undefined}},
  rpc:{register:async(_d,h)=>{handlers=h;return {events:{emit:async()=>{}},dispose:async()=>{}}}},
  event:{subscribe:async function*(){}}};
const dispose=await plugin.setup(ctx);
assert.equal((await handlers.searchSettings()).providers[0].connected,false);
await assert.rejects(()=>handlers.selectSearch({provider:'tavily'}));
assert.equal(selected,undefined);
authorized=true;
assert.equal((await handlers.selectSearch({provider:'tavily'})).selected,'tavily');
assert.equal(selected,'tavily');
await handlers.selectSearch({provider:null});assert.equal(selected,false);
await dispose();
''');
    final result = await Process.run('node', [file.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
