# Dynamic consistency boundaries

A consistency boundary need not be one aggregate's stream. With dynamic consistency boundaries it becomes "every event carrying these tags": [tag](events.md#tags) the events, read them back by type and tag, and append on the condition that none of the tags the decision depended on moved. The [`course-subscription`](../examples/course-subscription) example puts it all together.

## Querying by tag

`read(query, after: nil, limit: nil)` returns events selected by type and [tag](events.md#tags) rather than by aggregate:

```crystal
query = ES::Query.new(
  ES::QueryItem.new(CourseDefined, CourseCapacityChanged, tags: {course_id: course_id}),
  ES::QueryItem.new(StudentSubscribed, tags: {course_id: course_id}),
)

events = event_store.read(query)
events.last.position # => position of the last matching event
```

- An event matches an item when it is of one of the item's types and carries **all** of its tags. An event matches the query when it matches **any** item.
- An item without types matches every type (`ES::QueryItem.new(tags: {...})`). An item without tags matches regardless of tags. `ES::Query.all` matches every event.
- Tag values are given in plaintext. A value is hashed before matching when its key is declared `hashed: true` on an event, so a query never repeats that decision. A query for a hashed tag needs the tag hasher, like an append.
- Events come back in append order, each with its `position` in the store. Positions only increase but are not gapless. `after:` returns only events past a position, `limit:` caps how many are returned.
- Positions order events and page through results. They play no part in consistency, which rests on [tag versions](#tag-versions-and-conditional-appends). They are not commit-ordered: concurrent appends can commit in the opposite order of their positions. So don't use `after:` as a cursor to follow the store, because re-reading after the last position you saw can miss an event that committed late with a lower position.
- An event whose encryption key was destroyed still comes back, with its header (type, tags, position) and a `nil` body, flagged `body_erased?`. Erasure removes the data, not the fact that something happened. A course still counts the subscription of an erased student, and can show it as "deleted user". Materializing such an event into its class raises `ES::Exception::InvalidState`, so check `body_erased?` first.

In Postgres, `setup` creates a GIN index on `header->'tags'` (`jsonb_path_ops`) and a btree index on the event handle, on new and existing stores alike. On an existing store it builds the missing ones with `CREATE INDEX CONCURRENTLY`, so appends keep running during the build, but `setup` itself only returns once the build is done, which can take a while on a large store. Setups of an existing store running at the same time, such as several instances booting together, take turns through a Postgres advisory lock, so only one of them builds. Because the lock is a session lock, run `setup` over a session-mode connection, not through a pooler in transaction mode. `setup` waits for the lock without a time limit, so a session that holds it (key `0x6372797365736978`) holds up every `setup` of an existing store. A warning every 30 seconds names the backend holding it. A concurrent build also waits for every transaction in the database that started before it. A concurrent build that fails leaves an invalid index behind. `setup` builds an invalid index of its own again under a temporary name and swaps it in once valid. It leaves the index alone if an index build might still be running on the events table, or on Postgres before 12. It logs a warning for every invalid index left in the `eventstore` schema.

## Tag versions and conditional appends

Every tag has a **version** in the store: the number of events carrying it. Each tagged event raises the version of each of its tags by one, and the store stamps the new values into its header:

```json
"tags": ["course_id:0192…", "student_id:0193…"],
"tag_versions": {"course_id:0192…": 8, "student_id:0193…": 2}
```

Appends carrying the same tag never run at the same time, so the versions of one tag have no gaps and follow commit order, whatever positions the events get. That makes "the tag is still at version 8" mean exactly "nothing carrying this tag was appended since". This is the basis for consistency.

`append(events, condition)` appends a batch atomically, all or nothing. With an `ES::AppendCondition`, it appends only if every tag the condition names is still at the version it expects. Otherwise it raises `ES::Exception::Conflict` (HTTP 409), naming the tag key but never its value, and appends nothing.

**A decision read** returns the events of a query together with the current version of each of its tags, read in one snapshot so the two agree. Its `condition` guards the append the decision leads to:

```crystal
query = ES::Query.new(
  ES::QueryItem.new(CourseDefined, StudentSubscribed, tags: {course_id: course_id}),
  ES::QueryItem.new(StudentSubscribed, tags: {student_id: student_id}),
)
decision = event_store.read_for_decision(query)

# ... fold decision.events, decide, e.g. check the course isn't full ...

event_store.append(
  [StudentSubscribed.new(
    actor_id: actor, command_handler: "Subscribe", course_id: course_id, student_id: student_id,
    tags: {course_id: course_id, student_id: student_id}
  )],
  decision.condition
)
```

**Deciding on eventually consistent data.** Every stored event carries its tag versions, so anything that applied the events, such as a projection, knows which version of each tag it reflects. Pass those versions as the condition, and the append fails if any of those tags moved since the data was built:

```crystal
condition = ES::AppendCondition.new
  .expect(:user_id, user_id, version: 7)                 # plaintext tag; hashed if declared so
  .expect_stored("organization_id:0192…", 3)             # stored form, as found in header.tag_versions
```

**Uniqueness.** Version 0 means the tag was never used: `ES::AppendCondition.new.expect(:email, email, version: 0)`.

- **What a version counts:** every event carrying the tag, whatever its type and other tags. Any change to an expected tag fails the condition, including events of types the decision didn't read. Such a conflict causes a retry, never a missed conflict. Keep tags narrow (one course, one student) to keep retries rare.
- **Items without tags:** a decision read refuses any query item that names no tags, including `ES::Query.all`, because there is no tag whose version could detect a change. Plain `read` still accepts such items.
- **Versions are assigned by the store,** never taken from the event as given. An event read back and appended into another store gets that store's versions.
- `append(event)` still works and now returns the event's position. `append(events)` takes an array of any event type, e.g. `[StudentSubscribed.new(...)]`, without casting.
- **In Postgres:**
  - Versions live in `eventstore.tag_versions`, one row per distinct tag value, never deleted. `setup` creates the table on new and existing stores. Each row holds the stored tag, so a plain value such as an email address is kept there in the clear for as long as the store exists, in addition to the event headers. Use `hashed: true` for personal data.
  - An append locks the rows of all tags its events carry or its condition names, in one statement and in tag order, then checks, inserts and raises the versions in the same READ COMMITTED transaction. Two appends carrying the same tag therefore run one after the other. Untagged appends lock nothing.
  - `read` and `read_for_decision` take no locks. `read_for_decision` runs in a REPEATABLE READ snapshot.
- **The guarantee holds only if every writer raises tag versions:**
  - Don't insert into `eventstore.events` by other means.
  - During a rolling upgrade, wait until every writer runs 0.11 or later before relying on conditions.

The GIN index finds every event carrying a tag, but it can't narrow by position. A query therefore costs in proportion to the number of events carrying its tags. That is cheap for the narrow tags consistency boundaries are made of (one course, one student), and slow for a tag shared by a large part of the store, such as a tenant id.

## Decision projections

Folding `decision.events` by hand means writing the query and the fold separately, and nothing keeps them in step. A fold that handles an event type the query never selects decides on incomplete data, and the condition can't catch it, because it comes from the same query. An `ES::DecisionProjection` declares both at once, answering one question about the store:

```crystal
class CourseCapacity < ES::DecisionProjection(Int32?)
  def initialize(@course_id : UUID); end

  def initial_state : State
    nil
  end

  tags course_id: @course_id

  on CourseDefined do |_state, _event|
    body.capacity
  end
end

class CourseSubscribers < ES::DecisionProjection(Set(UUID))
  def initialize(@course_id : UUID); end

  def initial_state : State
    Set(UUID).new
  end

  tags course_id: @course_id

  on StudentSubscribed do |state, _event|
    state << body.student_id
  end
end
```

`build_decision_model` composes projections by name. It reads the events of all of them in one decision read, folds each over the events matching its own query, and returns their states with the condition:

```crystal
model = event_store.build_decision_model(
  capacity: CourseCapacity.new(course_id),
  subscribers: CourseSubscribers.new(course_id),
  student_courses: StudentCourseCount.new(student_id),
)
raise ES::Exception::InvalidState.new("Course is full") if model.state[:subscribers].size >= (model.state[:capacity] || 0)

event_store.append([StudentSubscribed.new(...)], model.condition)
```

- **The query is derived, never written:** the projection's event types are the classes it handles with `on`, and its tags are the ones named with `tags`. `query_item` returns it.
- **`model.state` is a named tuple,** typed per projection: `model.state[:capacity]` is an `Int32?`. `model.decision` is the underlying `ES::Decision`.
- **Handlers** take `|state, event|` and return the next state. They also see `body`, the event's body cast to its class. `initial_state` must return a fresh value on every call, and handlers should be pure: a fold may run again on a retry.
- **Prefer small projections** that each answer one question over one projection that answers many. An event matching several projections is folded into each, and one read serves them all, so their states agree.
- **Erased events:** an event whose body was erased with its encryption key raises `ES::Exception::InvalidState` when folded, rather than be skipped. Declare `on_erased EventClass do |state, header| ... end` to decide on it from its header, for example to count an erased student's registration. A body also comes back erased when its key is missing for any other reason, such as a misconfigured key store: `on_erased` can't tell the two apart.
- **`inspect` and `to_s`** of a projection name its class and tag keys, never the values. Those may be plaintext of hashed tags. A `DecisionModel` names its states and counts its events, without printing states or bodies.
- **Checked at compile time:**
  - a projection must handle at least one event and name its tags in exactly one `tags` call;
  - every handled class must be an `ES::Event` that declares each of the projection's tag keys, since otherwise it could never match;
  - a class can't be handled twice;
  - `on_erased` needs a matching `on`;
  - handler blocks must take two arguments;
  - `build_decision_model` needs at least one projection, and only accepts projections.
- **Conditions are as coarse as before:** the condition expects the versions of the projections' tags, whatever their types (see [What a version counts](#tag-versions-and-conditional-appends)).
