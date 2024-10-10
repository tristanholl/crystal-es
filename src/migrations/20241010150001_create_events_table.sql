+++ up
{
  CREATE TABLE "eventstore"."events" (
    "id" SERIAL PRIMARY KEY,
    "header" jsonb NOT NULL,
    "body" jsonb NOT NULL
  );
}

{
  CREATE UNIQUE INDEX aggregate_id_version_idx ON "eventstore"."events"((header->>'aggregate_id'), (header->>'aggregate_version'));
}

+++ down
{
  DROP TABLE "eventstore"."events";
}
