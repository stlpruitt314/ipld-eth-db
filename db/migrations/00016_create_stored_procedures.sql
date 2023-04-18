-- +goose Up
-- +goose StatementBegin
-- returns whether the state leaf key is vacated (previously existed but now is empty) at the provided block hash
CREATE OR REPLACE FUNCTION was_state_leaf_removed(v_key VARCHAR(66), v_hash VARCHAR)
    RETURNS boolean AS $$
    SELECT state_cids.removed = true
    FROM eth.state_cids
             INNER JOIN eth.header_cids ON (state_cids.header_id = header_cids.block_hash)
    WHERE state_leaf_key = v_key
      AND state_cids.block_number <= (SELECT block_number
                           FROM eth.header_cids
                           WHERE block_hash = v_hash)
    ORDER BY state_cids.block_number DESC LIMIT 1;
$$
language sql;
-- +goose StatementEnd

-- +goose StatementBegin
-- returns whether the state leaf key is vacated (previously existed but now is empty) at the provided block height
CREATE OR REPLACE FUNCTION public.was_state_leaf_removed_by_number(v_key VARCHAR(66), v_block_no BIGINT)
    RETURNS BOOLEAN AS $$
    SELECT state_cids.removed = true
    FROM eth.state_cids
             INNER JOIN eth.header_cids ON (state_cids.header_id = header_cids.block_hash)
    WHERE state_leaf_key = v_key
      AND state_cids.block_number <= v_block_no
    ORDER BY state_cids.block_number DESC LIMIT 1;
$$
language sql;
-- +goose StatementEnd

-- +goose StatementBegin
-- duplicate of eth.header_cids as a separate type: if we use the table directly, dropping the hypertables
-- on downgrade of step 00018 will fail due to the dependency on this type.
CREATE TYPE header_result AS (
    block_number bigint,
    block_hash character varying(66),
    parent_hash character varying(66),
    cid text,
    td numeric,
    node_ids character varying(128)[],
    reward numeric,
    state_root character varying(66),
    tx_root character varying(66),
    receipt_root character varying(66),
    uncles_hash character varying(66),
    bloom bytea,
    "timestamp" bigint,
    coinbase character varying(66)
);

CREATE TYPE child_result AS (
    has_child BOOLEAN,
    children header_result[]
);

CREATE OR REPLACE FUNCTION get_child(hash VARCHAR(66), height BIGINT) RETURNS child_result AS
$BODY$
DECLARE
  child_height INT;
  temp_child header_result;
  new_child_result child_result;
BEGIN
  child_height = height + 1;
  -- short circuit if there are no children
  SELECT exists(SELECT 1
              FROM eth.header_cids
              WHERE parent_hash = hash
                AND block_number = child_height
              LIMIT 1)
  INTO new_child_result.has_child;
  -- collect all the children for this header
  IF new_child_result.has_child THEN
    FOR temp_child IN
    SELECT * FROM eth.header_cids WHERE parent_hash = hash AND block_number = child_height
    LOOP
      new_child_result.children = array_append(new_child_result.children, temp_child);
    END LOOP;
  END IF;
  RETURN new_child_result;
END
$BODY$
LANGUAGE 'plpgsql';
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION canonical_header_from_array(headers header_result[]) RETURNS header_result AS
$BODY$
DECLARE
  canonical_header header_result;
  canonical_child header_result;
  header header_result;
  current_child_result child_result;
  child_headers header_result[];
  current_header_with_child header_result;
  has_children_count INT DEFAULT 0;
BEGIN
  -- for each header in the provided set
  FOREACH header IN ARRAY headers
  LOOP
    -- check if it has any children
    current_child_result = get_child(header.block_hash, header.block_number);
    IF current_child_result.has_child THEN
      -- if it does, take note
      has_children_count = has_children_count + 1;
      current_header_with_child = header;
      -- and add the children to the growing set of child headers
      child_headers = array_cat(child_headers, current_child_result.children);
    END IF;
  END LOOP;
  -- if none of the headers had children, none is more canonical than the other
  IF has_children_count = 0 THEN
    -- return the first one selected
    SELECT * INTO canonical_header FROM unnest(headers) LIMIT 1;
  -- if only one header had children, it can be considered the heaviest/canonical header of the set
  ELSIF has_children_count = 1 THEN
    -- return the only header with a child
    canonical_header = current_header_with_child;
  -- if there are multiple headers with children
  ELSE
    -- find the canonical header from the child set
    canonical_child = canonical_header_from_array(child_headers);
    -- the header that is parent to this header, is the canonical header at this level
    SELECT * INTO canonical_header FROM unnest(headers)
    WHERE block_hash = canonical_child.parent_hash;
  END IF;
  RETURN canonical_header;
END
$BODY$
LANGUAGE 'plpgsql';
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION canonical_header_hash(height BIGINT) RETURNS character varying AS
$BODY$
DECLARE
  canonical_header header_result;
  headers header_result[];
  header_count INT;
  temp_header header_result;
BEGIN
  -- collect all headers at this height
  FOR temp_header IN
  SELECT * FROM eth.header_cids WHERE block_number = height
  LOOP
    headers = array_append(headers, temp_header);
  END LOOP;
  -- count the number of headers collected
  header_count = array_length(headers, 1);
  -- if we have less than 1 header, return NULL
  IF header_count IS NULL OR header_count < 1 THEN
    RETURN NULL;
  -- if we have one header, return its hash
  ELSIF header_count = 1 THEN
    RETURN headers[1].block_hash;
  -- if we have multiple headers we need to determine which one is canonical
  ELSE
    canonical_header = canonical_header_from_array(headers);
    RETURN canonical_header.block_hash;
  END IF;
END
$BODY$
LANGUAGE 'plpgsql';
-- +goose StatementEnd

-- +goose Down
DROP FUNCTION was_state_leaf_removed;
DROP FUNCTION was_state_leaf_removed_by_number;
DROP FUNCTION canonical_header_hash;
DROP FUNCTION canonical_header_from_array;
DROP FUNCTION get_child;
DROP TYPE child_result;
