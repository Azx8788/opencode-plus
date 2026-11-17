const insightsPluginJs = r'''
import { Plugin } from '@opencode/plugin';
import { Insights } from './rpc.js';
import { append } from './core.js';

export default Plugin.define({
  id: 'mobile-insights',
  async setup(ctx) {
    const key = 'events/v1';
    const saved = await ctx.storage.get(key);
    if (saved && (saved.version !== 1 || !Array.isArray(saved.entries) || !Number.isSafeInteger(saved.seq))) {
      throw new Error('Mobile insights history is unreadable; existing data was not overwritten');
    }
    let snapshot = saved ?? {version:1,seq:0,entries:[],truncated:false};
    let error = null, writes = Promise.resolve();
    let selection = await ctx.storage.get('search/selection');
    let effective;
    const apply = () => ctx.websearch.transform(editor => {
      if (selection === false) editor.default.set(false);
      else if (typeof selection === 'string') editor.default.set(selection);
      effective = editor.default.get();
    });
    await apply();
    const searchSettings = async () => {
      const providers = await ctx.websearch.providers();
      const list = Array.isArray(providers) ? providers : providers.data;
      if (!Array.isArray(list)) throw new Error('Invalid search catalogue');
      const options = [];
      for (const provider of list) {
        const connection = await ctx.integration.connection.active(provider.id);
        options.push({id:provider.id,name:provider.name,connected:connection != null});
      }
      return {selected: typeof effective === 'string' ? effective : null,
        enabled:effective !== false,providers:options};
    };
    const rpc = await ctx.rpc.register(Insights, {
      searchSettings,
      selectSearch: async ({provider}) => {
        if (provider !== null) {
          const current = await searchSettings();
          const option = current.providers.find(p => p.id === provider);
          if (!option || !option.connected) throw new Error('Connect this search provider before selecting it');
        }
        const before = selection;
        selection = provider === null ? false : provider;
        try {
          await ctx.websearch.reload();
          await ctx.storage.set('search/selection',selection);
        } catch (e) { selection = before; await ctx.websearch.reload(); throw e; }
        return searchSettings();
      },
      status: async () => ({version:1,seq:snapshot.seq,truncated:snapshot.truncated,error,now:Date.now()}),
      history: async ({sessionID,after=0,limit=500}) => {
        await writes;
        if (error) throw new Error(error);
        const rows = snapshot.entries.filter(e => e.seq > after && (!sessionID || e.sessionID === sessionID));
        const entries = rows.slice(0,limit);
        return {version:1,entries,next:rows.length>limit ? entries.at(-1).seq : null,truncated:snapshot.truncated,now:Date.now()};
      },
    });
    const controller = new AbortController();
    const consume = (async () => {
      try {
        for await (const event of ctx.event.subscribe({signal:controller.signal})) {
          const next = append(snapshot,event);
          if (next === snapshot) continue;
          // Ordered bounded writes; publishing happens only after durability.
          const operation = writes.then(async () => {
            const updated = append(snapshot,event);
            if (updated === snapshot) return;
            await ctx.storage.set(key,updated);
            snapshot = updated;
            error = null;
            await rpc.events.emit('changed',{sessionID:event.data.sessionID,seq:snapshot.seq});
          });
          writes = operation.catch(() => { error = 'Mobile insights recording failed'; });
          await writes;
        }
      } catch (_) { if (!controller.signal.aborted) error = 'Mobile insights event stream disconnected'; }
    })();
    return async () => {controller.abort();await consume;await writes;await rpc.dispose();};
  },
});
''';
