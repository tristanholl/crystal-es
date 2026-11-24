# Events

`ES::Event` is the base class for all domain events. Each event carries a **Header** (metadata) and a **Body** (event-specific payload).

```crystal
class OrderPlaced < ES::Event
  aggregate_type "order"
  event_handle "order_placed"

  class Body
    include JSON::Serializable
    getter order_id : UUID
    getter amount : Int64

    def initialize(@order_id, @amount); end
  end
end
```

## Event DSL

The `define_event` macro removes the boilerplate. It generates the full event class, the `Body` struct with JSON serialization, and registers the handle automatically.

```crystal
define_event("order", "order_placed") do
  attribute :order_id, UUID
  attribute :amount, Int64
  attribute :currency, String, "EUR"   # optional default
end
```

`attribute(name, type, default?)` — declare a typed field on the event body. A default value makes the field optional at construction time. Declare attributes without a default before those with one; the compiler rejects the other order.

## Tags

`tag(name, type, hashed: false)` — declare a tag: a value carried in the event header. Tags are the groundwork for dynamic consistency boundaries: instead of one aggregate's stream, a consistency boundary becomes "every event carrying these tags".

Tags and attributes are independent of each other. A tag may share its name with an attribute, and may hold the same value or a different one. It can also name something the body doesn't carry at all, such as a second aggregate whose consistency the event takes part in, without coupling it into the payload.

```crystal
define_event("course", "student_subscribed") do
  attribute :course_id, UUID
  attribute :student_id, UUID
  tag :course_id, UUID                 # stored as "course_id:<uuid>"
  tag :student_id, UUID
end

define_event("student", "student_registered") do
  attribute :student_id, UUID
  tag :student_id, UUID
  tag :email, String, hashed: true     # stored as "email:<hmac>", the value nowhere else
end

StudentSubscribed.new(
  actor_id: actor, command_handler: "Subscribe",
  course_id: course_id, student_id: student_id,
  tags: {course_id: course_id, student_id: student_id}
)
```

- The constructor takes the tag values as one `tags:` named tuple, whose keys and types the compiler checks against the declarations. Every declared tag must be present. One declared with a nilable type, such as `UUID?`, may be `nil`, and then the event carries no such tag. An event without tags has no `tags:` argument. Pass `tags:` by name: it sits after the attributes without a default and before those with one.
- Values are stored in their `to_s` form, so a query matches when it passes a value with the same `to_s`. In practice, use the same type.
- The event store writes tags to the event header (`header.tags`) on append, in their stored form, together with their versions (`header.tag_versions`, see [Tag versions](consistency.md#tag-versions-and-conditional-appends)). `event.tags` holds the plaintext values the event was built with. An event read back only has the stored form, and a hashed tag only its digest. Put a value in an attribute too if code needs it after reading the event back. Appending a read-back event again keeps its stored tags exactly as they are, without hashing them again. A store with a different application key, or with no tag hasher, won't find its hashed tags. Stored tags are checked before they are kept, because a header can also come from elsewhere, such as a queue message. Every key must be declared by the event class, and a hashed key must hold a digest. Otherwise the append raises `ES::Exception::InvalidState`.
- A tag without a type, a duplicate tag, an unknown option, a non-boolean `hashed:`, or an attribute named `tags` next to declared tags is a compile error.
- If the same tag key is `hashed: true` in one event and `hashed: false` in another, compilation emits a warning. Keeping a key consistent across events is the application's job: a query hashes a tag value according to how the key is declared, so the inconsistent events would not be found.

**Hashed tags.** `hashed: true` stores an HMAC-SHA256 of the value (truncated to 128 bits), keyed by a key derived from the application encryption key. It is off by default and has to be switched on:

```crystal
ES::Config.tag_hasher = ES::TagHasher.new(application_key) # ES::ApplicationEncryptionKeyManager
```

Unhashed tags need no configuration. Appending an event with a hashed tag while no hasher is configured raises `ES::Exception::InvalidState`, rather than storing the value in the clear. Event stores read `ES::Config.tag_hasher` when they are constructed, so configure it before building them, or pass `tag_hasher:` to the store directly.

What hashing does and does not protect:

- A database dump alone does not reveal hashed values. A plain hash would: email addresses and names fall to a dictionary attack within seconds, which is why the digest is keyed.
- The same value always yields the same digest, which is what lets a query find it. Whoever holds the application key can therefore still test whether a known value appears in the store. A hashed tag is pseudonymous data, not anonymous data.
- Tags are not crypto-shredded. Destroying an event's encryption key erases its body, but not its tags. A tag holding personal data outlives the erasure. An unhashed tag on an `encrypted: true` event stores its value in the clear in the header, even if the body holds the same value encrypted.
- Hashing only keeps a value out of the header. If the body carries the same value as an attribute of an event without `encrypted: true`, the value is still stored in the clear there. A hashed tag whose value lives in no attribute (and not in the free-text `comment`) is stored only as its digest.
- The derived key cannot be rotated: every stored digest depends on it, the same way every wrapped data key depends on the application key.

Prefer tagging by a surrogate id (a UUID) over personal data. Use `hashed: true` where that isn't possible.
