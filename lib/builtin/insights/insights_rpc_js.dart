/// Public RPC contract for the app-owned OpenCode V2 plugin. No tool or
/// credential is added to the model's prompt by this contract.
const insightsRpcJs = r'''
import { Rpc } from '@opencode/plugin/rpc';
const object = (properties, required = []) => ({
  type: 'object', properties, required, additionalProperties: false,
});
export const Insights = Rpc.define({
  id: 'mobile-insights',
  methods: {
    searchSettings: { input: object({}), output:{type:'object'} },
    selectSearch: { input: object({ provider: {type: ['string','null']} }, ['provider']), output:{type:'object'} },
    history: { input: object({ sessionID: {type:'string'}, after: {type:'integer',minimum:0}, limit: {type:'integer',minimum:1,maximum:500} }), output:{type:'object'} },
    status: { input: object({}), output:{type:'object'} },
  },
  events: { changed: {schema: object({sessionID:{type:'string'}, seq:{type:'integer'}}, ['sessionID','seq'])} },
});
''';
