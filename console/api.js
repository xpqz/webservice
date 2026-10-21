// Every call to the Issues API goes through call(), so the request log sees it.
import { reactive } from 'vue'

const API = `${location.protocol}//${location.hostname}:8080`
let nextId = 1

export const log = reactive([])     // newest first, last 50 requests

export async function call(method, path, body) {
  const entry = { id: nextId++, method, path, request: body, status: '…', worker: '', ms: 0, response: null }
  log.unshift(entry)
  log.splice(50)
  const started = performance.now()
  try {
    const res = await fetch(API + path, {
      method,
      headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    })
    const text = await res.text()
    entry.status = res.status
    entry.worker = res.headers.get('X-Worker') ?? ''
    entry.response = text ? JSON.parse(text) : null
    if (!res.ok) throw Object.assign(new Error(entry.response?.message ?? res.statusText), { data: entry.response })
    return entry.response
  } catch (e) {
    if (entry.status === '…') entry.status = 'failed'    // network error: no response at all
    throw e
  } finally {
    entry.ms = Math.round(performance.now() - started)
  }
}

// The API's error message, with GitHub-style field errors if there are any
export function describe(e) {
  const fields = e.data?.errors?.map(x => `${x.field} ${x.code.replace('_', ' ')}`).join(', ')
  return fields ? `${e.message}: ${fields}` : e.message
}
