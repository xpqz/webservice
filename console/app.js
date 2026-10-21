import { createApp, reactive, ref, watch, onMounted } from 'vue'
import { call, describe, log } from './api.js'

const PER_PAGE = 20

// 2026-10-20T16:09:52Z → 2026-10-20 16:09 (UTC)
const when = iso => iso.slice(0, 16).replace('T', ' ')

// What the whole page shares: the open issue, whether we're writing a new
// one, and a counter that tells the list to reload after any change.
const store = reactive({
  selected: null,
  creating: false,
  changes: 0,
  open(number) { this.selected = number; this.creating = false },
})

const IssueList = {
  setup() {
    const filter = reactive({ state: 'open', label: '', page: 1 })
    const issues = ref([]), labels = ref([]), error = ref('')

    async function load() {
      const query = new URLSearchParams({ state: filter.state, page: filter.page, per_page: PER_PAGE })
      if (filter.label) query.set('labels', filter.label)
      try { issues.value = await call('GET', `/issues?${query}`); error.value = '' }
      catch (e) { error.value = describe(e) }
    }

    onMounted(async () => {
      labels.value = await call('GET', '/labels?per_page=100').catch(() => [])
      load()
    })
    watch(() => [filter.state, filter.label], () => { filter.page = 1; load() })
    watch(() => [filter.page, store.changes], load)
    return { filter, issues, labels, error, store, PER_PAGE }
  },
  template: `
    <section class="list">
      <div class="filters">
        <select v-model="filter.state">
          <option>open</option><option>closed</option><option>all</option>
        </select>
        <select v-model="filter.label">
          <option value="">any label</option>
          <option v-for="l in labels" :key="l.id" :value="l.name">{{ l.name }}</option>
        </select>
      </div>
      <p v-if="error" class="error">{{ error }}</p>
      <ul>
        <li v-for="i in issues" :key="i.number" :class="{ active: i.number === store.selected }"
            @click="store.open(i.number)">
          <span class="number">#{{ i.number }}</span> <span class="title">{{ i.title }}</span>
          <span v-for="l in i.labels" :key="l.id" class="label"><i :style="{ background: '#' + l.color }"></i>{{ l.name }}</span>
          <span v-if="i.state === 'closed'" class="closed">closed</span>
        </li>
        <li v-if="!issues.length" class="empty">No issues</li>
      </ul>
      <div class="pager">
        <button :disabled="filter.page === 1" @click="filter.page--">‹ prev</button>
        page {{ filter.page }}
        <button :disabled="issues.length < PER_PAGE" @click="filter.page++">next ›</button>
      </div>
    </section>`,
}

// Used both for a new issue (no issue prop) and for editing one
const IssueForm = {
  props: ['issue'],
  emits: ['done'],
  setup(props, { emit }) {
    const form = reactive({ title: props.issue?.title ?? '', body: props.issue?.body ?? '' })
    const error = ref('')
    async function save() {
      try {
        const saved = props.issue
          ? await call('PATCH', `/issues/${props.issue.number}`, form)
          : await call('POST', '/issues', form)
        store.changes++
        store.open(saved.number)
        emit('done')
      } catch (e) { error.value = describe(e) }
    }
    function cancel() { store.creating = false; emit('done') }
    return { form, error, save, cancel }
  },
  template: `
    <form class="issue-form" @submit.prevent="save">
      <h2>{{ issue ? 'Edit issue #' + issue.number : 'New issue' }}</h2>
      <input v-model="form.title" placeholder="Title">
      <textarea v-model="form.body" rows="8" placeholder="Description"></textarea>
      <p v-if="error" class="error">{{ error }}</p>
      <button type="submit">Save</button> <button type="button" @click="cancel">Cancel</button>
    </form>`,
}

const IssueView = {
  components: { IssueForm },
  setup() {
    const issue = ref(null), comments = ref([]), comment = ref(''), error = ref(''), editing = ref(false)

    async function load() {
      try {
        issue.value = await call('GET', `/issues/${store.selected}`)
        comments.value = await call('GET', `/issues/${store.selected}/comments?per_page=100`)
        error.value = ''
      } catch (e) { error.value = describe(e) }
    }

    // Run a change, then refresh this issue and the list
    async function change(request) {
      try { await request(); error.value = ''; store.changes++; await load(); return true }
      catch (e) { error.value = describe(e); return false }
    }
    const setState = state => change(() => call('PATCH', `/issues/${issue.value.number}`, { state }))
    async function addComment() {
      if (await change(() => call('POST', `/issues/${issue.value.number}/comments`, { body: comment.value }))) comment.value = ''
    }

    watch(() => store.selected, () => { editing.value = false; load() }, { immediate: true })
    return { issue, comments, comment, error, editing, setState, addComment, load, when }
  },
  template: `
    <section v-if="issue" class="issue">
      <issue-form v-if="editing" :issue="issue" @done="editing = false; load()"></issue-form>
      <template v-else>
        <h2>#{{ issue.number }} {{ issue.title }}</h2>
        <p class="meta">
          <span :class="['state', issue.state]">{{ issue.state }}</span>
          <span v-if="issue.state_reason">({{ issue.state_reason.replace('_', ' ') }})</span>
          <span v-for="l in issue.labels" :key="l.id" class="label"><i :style="{ background: '#' + l.color }"></i>{{ l.name }}</span>
          <span class="dates">opened {{ when(issue.created_at) }}</span>
        </p>
        <div class="actions">
          <button @click="editing = true">Edit</button>
          <button v-if="issue.state === 'open'" @click="setState('closed')">Close</button>
          <button v-else @click="setState('open')">Reopen</button>
        </div>
        <p class="body">{{ issue.body ?? 'No description.' }}</p>
        <h3>Comments ({{ comments.length }})</h3>
        <div v-for="c in comments" :key="c.id" class="comment">
          <span class="dates">{{ when(c.created_at) }}</span>
          <p>{{ c.body }}</p>
        </div>
        <form @submit.prevent="addComment" class="add-comment">
          <textarea v-model="comment" rows="3" placeholder="Add a comment"></textarea>
          <button type="submit">Comment</button>
        </form>
      </template>
      <p v-if="error" class="error">{{ error }}</p>
    </section>
    <p v-else-if="error" class="error">{{ error }}</p>`,
}

const RequestLog = {
  setup() { return { log, expanded: ref(null) } },
  template: `
    <section class="log">
      <h3>Requests <small>(newest first — click one to see the JSON)</small></h3>
      <div v-for="r in log" :key="r.id" class="entry" @click="expanded = expanded === r.id ? null : r.id">
        <div class="line">
          <code>{{ r.method }} {{ r.path }}</code>
          <b :class="'s' + String(r.status)[0]">{{ r.status }}</b>
          <span>{{ r.worker }}</span><span>{{ r.ms }} ms</span>
        </div>
        <div v-if="expanded === r.id" class="json">
          <pre v-if="r.request !== undefined">request  {{ JSON.stringify(r.request, null, 2) }}</pre>
          <pre>response {{ JSON.stringify(r.response, null, 2) }}</pre>
        </div>
      </div>
    </section>`,
}

createApp({
  components: { IssueList, IssueView, IssueForm, RequestLog },
  setup() { return { store } },
  template: `
    <header>
      <h1>Issues</h1>
      <button @click="store.creating = true">New issue</button>
    </header>
    <main>
      <issue-list></issue-list>
      <div class="detail">
        <issue-form v-if="store.creating"></issue-form>
        <issue-view v-else-if="store.selected"></issue-view>
        <p v-else class="empty">Select an issue, or create one.</p>
      </div>
    </main>
    <request-log></request-log>`,
}).mount('#app')
