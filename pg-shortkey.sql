-- by Nathan Fritz (andyet.com); turbo (github.com/turbo)
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- can't query pg_type because type might exist in other schemas
-- no IF NOT EXISTS for CREATE DOMAIN, need to catch exception
DO $$ BEGIN
  CREATE DOMAIN SHORTKEY as varchar(11);
EXCEPTION
  WHEN duplicate_object THEN null;
END $$;

CREATE OR REPLACE FUNCTION shortkey_generate()
RETURNS TRIGGER AS $$
DECLARE
  gkey TEXT;
  key SHORTKEY;
  qry TEXT;
  found TEXT;
  user_id BOOLEAN;
BEGIN
  -- generate the query as a string with safely escaped table name
  -- and a placeholder for the value
  qry := format('SELECT EXISTS (SELECT FROM %I WHERE id=$1)', TG_TABLE_NAME);

  LOOP
    -- deal with user-supplied keys, they don't have to be valid base64
    -- only the right length for the type
    IF NEW.id IS NOT NULL THEN
      key := NEW.id;
      user_id := TRUE;

      IF length(key) <> 11 THEN
        RAISE 'User defined key value % has invalid length. Expected 11, got %.', key, length(key);
      END IF;
    ELSE
      -- 8 bytes gives a collision p = .5 after 5.1 x 10^9 values
      gkey := encode(gen_random_bytes(8), 'base64');
      gkey := replace(gkey, '/', '_');  -- url safe replacement
      gkey := replace(gkey, '+', '-');  -- url safe replacement
      key := rtrim(gkey, '=');          -- cut off padding
      user_id := FALSE;
    END IF;

    -- Check for collision
    -- SELECT EXISTS (SELECT FROM "test" WHERE id='blahblah') INTO found
    EXECUTE qry INTO found USING key;

    IF NOT found THEN
      -- If we didn't find a collision then leave the LOOP.
      EXIT;
    END IF;

    IF user_id THEN
      -- User supplied ID but it violates the PK unique constraint
      RAISE 'ID % already exists in table %', key, TG_TABLE_NAME;
    END IF;

    -- We haven't EXITed yet, so return to the top of the LOOP
    -- and try again.
  END LOOP;

  -- NEW and OLD are available in TRIGGER PROCEDURES.
  -- NEW is the mutated row that will actually be INSERTed.
  -- We're replacing id, regardless of what it was before
  -- with our key variable.
  NEW.id = key;

  -- The RECORD returned here is what will actually be INSERTed,
  -- or what the next trigger will get if there is one.
  RETURN NEW;
END
$$ language 'plpgsql';
