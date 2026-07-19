// GET /api/creators?cursor=&limit=50&q=&category=&minFollowers=
// Keyset (cursor) pagination — the ONLY way to page millions of rows fast.
// RLS ensures a caller only ever gets their own tenant's creators.
import { supabase } from '../../../lib/supabase';

export async function GET(req) {
  const url = new URL(req.url);
  const limit = Math.min(100, parseInt(url.searchParams.get('limit') || '50', 10));
  const q = url.searchParams.get('q') || '';
  const category = url.searchParams.get('category') || '';
  const minFollowers = parseInt(url.searchParams.get('minFollowers') || '0', 10);
  const cursor = url.searchParams.get('cursor'); // followers value of last row

  let query = supabase
    .from('creators')
    .select('id,handle,name,platform,followers,engagement,category,city,brand_cost,profile_url')
    .order('followers', { ascending: false })
    .limit(limit);

  if (q) query = query.or(`handle.ilike.%${q}%,name.ilike.%${q}%`);
  if (category) query = query.eq('category', category);
  if (minFollowers) query = query.gte('followers', minFollowers);
  if (cursor) query = query.lt('followers', parseInt(cursor, 10));

  const { data, error } = await query;
  if (error) return Response.json({ ok: false, error: error.message }, { status: 500 });
  const nextCursor = data.length === limit ? data[data.length - 1].followers : null;
  return Response.json({ ok: true, creators: data, nextCursor });
}
