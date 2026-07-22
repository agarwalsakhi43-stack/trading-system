/**
 * Core drawing logic.
 */
import { evaluate, getChartApi } from '../connection.js';

export async function drawShape({ shape, point, point2, overrides: overridesRaw, text }) {
  const overrides = overridesRaw ? (typeof overridesRaw === 'string' ? JSON.parse(overridesRaw) : overridesRaw) : {};
  const apiPath = await getChartApi();
  const overridesStr = JSON.stringify(overrides || {});
  const textStr = text ? JSON.stringify(text) : '""';

  const before = await evaluate(`${apiPath}.getAllShapes().map(function(s) { return s.id; })`);

  if (point2) {
    await evaluate(`
      ${apiPath}.createMultipointShape(
        [{ time: ${point.time}, price: ${point.price} }, { time: ${point2.time}, price: ${point2.price} }],
        { shape: '${shape}', overrides: ${overridesStr}, text: ${textStr} }
      )
    `);
  } else {
    await evaluate(`
      ${apiPath}.createShape(
        { time: ${point.time}, price: ${point.price} },
        { shape: '${shape}', overrides: ${overridesStr}, text: ${textStr} }
      )
    `);
  }

  await new Promise(r => setTimeout(r, 200));
  const after = await evaluate(`${apiPath}.getAllShapes().map(function(s) { return s.id; })`);
  const newId = (after || []).find(id => !(before || []).includes(id)) || null;
  const result = { entity_id: newId };
  return { success: true, shape, entity_id: result?.entity_id };
}

export async function listDrawings() {
  const apiPath = await getChartApi();
  const shapes = await evaluate(`
    (function() {
      var api = ${apiPath};
      var all = api.getAllShapes();
      return all.map(function(s) { return { id: s.id, name: s.name }; });
    })()
  `);
  return { success: true, count: shapes?.length || 0, shapes: shapes || [] };
}

export async function getProperties({ entity_id }) {
  const apiPath = await getChartApi();
  const result = await evaluate(`
    (function() {
      var api = ${apiPath};
      var eid = '${entity_id}';
      var props = { entity_id: eid };
      var shape = api.getShapeById(eid);
      if (!shape) return { error: 'Shape not found: ' + eid };
      var methods = [];
      try { for (var key in shape) { if (typeof shape[key] === 'function') methods.push(key); } props.available_methods = methods; } catch(e) {}
      try { var pts = shape.getPoints(); if (pts) props.points = pts; } catch(e) { props.points_error = e.message; }
      try { var ovr = shape.getProperties(); if (ovr) props.properties = ovr; } catch(e) {
        try { var ovr2 = shape.properties(); if (ovr2) props.properties = ovr2; } catch(e2) { props.properties_error = e2.message; }
      }
      try { props.visible = shape.isVisible(); } catch(e) {}
      try { props.locked = shape.isLocked(); } catch(e) {}
      try { props.selectable = shape.isSelectionEnabled(); } catch(e) {}
      try {
        var all = api.getAllShapes();
        for (var i = 0; i < all.length; i++) { if (all[i].id === eid) { props.name = all[i].name; break; } }
      } catch(e) {}
      return props;
    })()
  `);
  if (result?.error) throw new Error(result.error);
  return { success: true, ...result };
}

export async function removeOne({ entity_id }) {
  const apiPath = await getChartApi();
  const result = await evaluate(`
    (function() {
      var api = ${apiPath};
      var eid = '${entity_id}';
      var before = api.getAllShapes();
      var found = false;
      for (var i = 0; i < before.length; i++) { if (before[i].id === eid) { found = true; break; } }
      if (!found) return { removed: false, error: 'Shape not found: ' + eid, available: before.map(function(s) { return s.id; }) };
      api.removeEntity(eid);
      var after = api.getAllShapes();
      var stillExists = false;
      for (var j = 0; j < after.length; j++) { if (after[j].id === eid) { stillExists = true; break; } }
      return { removed: !stillExists, entity_id: eid, remaining_shapes: after.length };
    })()
  `);
  if (result?.error) throw new Error(result.error);
  return { success: true, entity_id: result?.entity_id, removed: result?.removed, remaining_shapes: result?.remaining_shapes };
}

export async function clearAll() {
  const apiPath = await getChartApi();
  await evaluate(`${apiPath}.removeAllShapes()`);
  return { success: true, action: 'all_shapes_removed' };
}

export async function safeDrawSRLevels({ support, resistance }) {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const apiPath = await getChartApi();

  // Enforce max 3 per side, 6 total
  const supportLevels    = (support    || []).slice(0, 3);
  const resistanceLevels = (resistance || []).slice(0, 3);
  const totalLevels = supportLevels.length + resistanceLevels.length;
  if (totalLevels === 0) throw new Error('Provide at least one price in support or resistance arrays');

  // ── Step 1: clear all existing drawings and wait for it to settle ──
  await evaluate(`${apiPath}.removeAllShapes()`);
  await sleep(600);
  const remaining = await evaluate(`${apiPath}.getAllShapes().length`);
  if (remaining > 0) {
    await evaluate(`${apiPath}.removeAllShapes()`);
    await sleep(600);
  }

  // Anchor time = now (horizontal lines span the whole chart regardless)
  const refTime = Math.floor(Date.now() / 1000);

  const drawn   = [];
  const failed  = [];

  // ── Step 2: draw one line at a time with 1-second gap + verification ──
  async function drawLevel(price, color) {
    const beforeIds = await evaluate(
      `${apiPath}.getAllShapes().map(function(s){ return s.id; })`
    );

    try {
      await evaluate(`
        (function() {
          var api = ${apiPath};
          api.createShape(
            { time: ${refTime}, price: ${price} },
            {
              shape: 'horizontal_line',
              overrides: {
                linecolor:        '${color}',
                linewidth:        2,
                linestyle:        0,
                showLabel:        false,
                horzLabelsAlign:  'right',
                vertLabelsAlign:  'middle'
              }
            }
          );
        })()
      `);
    } catch (err) {
      return { ok: false, reason: 'createShape threw: ' + err.message };
    }

    await sleep(1000);

    const afterIds = await evaluate(
      `${apiPath}.getAllShapes().map(function(s){ return s.id; })`
    );
    const newId = (afterIds || []).find(id => !(beforeIds || []).includes(id));
    if (!newId) return { ok: false, reason: 'entity ID did not appear after draw' };
    return { ok: true, entity_id: newId };
  }

  // Support = green, Resistance = red (TradingView-standard colours)
  const levels = [
    ...supportLevels.map(p    => ({ price: p,    color: '#26a69a', type: 'support'    })),
    ...resistanceLevels.map(p => ({ price: p,    color: '#ef5350', type: 'resistance' })),
  ];

  for (const { price, color, type } of levels) {
    const result = await drawLevel(price, color);
    if (result.ok) {
      drawn.push({ type, price, entity_id: result.entity_id });
    } else {
      failed.push({ type, price, reason: result.reason });
    }
  }

  return {
    success:  drawn.length > 0,
    drawn:    drawn.length,
    failed:   failed.length,
    max_allowed: 6,
    levels:   drawn,
    failures: failed,
  };
}
