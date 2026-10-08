-- Migration to prevent duplicate responses from the same device and enforce maximum submission limit
-- Adds device_id to responses and updates guard_response trigger.

alter table responses add column if not exists device_id text;

-- Unique constraint ensuring one submission per device per form
create unique index if not exists responses_form_device_idx
  on responses (form_id, device_id)
  where device_id is not null;

-- Update guard_response trigger to validate device_id and enforce duplicate check server side
create or replace function guard_response() returns trigger
language plpgsql security definer set search_path = public as $guard$
declare
  f            forms%rowtype;
  deadline_ts  timestamp;
  recent       integer;
  q            jsonb;
  answer       jsonb;
  key          text;
  label        text;
  blank        boolean;
  num          numeric;
  expected     text;
begin
  select * into f from forms where id = new.form_id;
  if not found then
    raise exception 'That form does not exist'
      using errcode = 'foreign_key_violation';
  end if;

  new.submitted_at := now();
  new.status := 'new';
  new.public_note := '';

  if new.ref is null
     or char_length(new.ref) <> 16
     or new.ref !~ '^[0-9a-f]+$' then
    raise exception 'A response needs a 16-character reference code'
      using errcode = 'check_violation';
  end if;
  new.ref := lower(new.ref);

  -- Server-side check for maximum submission limit
  if f.max_responses is not null and f.response_count >= f.max_responses then
    raise exception 'This form is full'
      using errcode = 'check_violation';
  end if;

  -- Server-side check for duplicate device submission
  if new.device_id is not null and char_length(new.device_id) > 0 then
    if exists (
      select 1 from responses
       where form_id = new.form_id
         and device_id = new.device_id
    ) then
      raise exception 'You have already submitted a response to this form from this device.'
        using errcode = 'check_violation';
    end if;
  end if;

  if f.deadline is not null then
    deadline_ts := case
      when f.deadline ~ '^\d{4}-\d{2}-\d{2}$' then (f.deadline::date + interval '1 day')::timestamp
      else replace(f.deadline, 'T', ' ')::timestamp
    end;
    if (now() at time zone 'utc') > deadline_ts + interval '14 hours' then
      raise exception 'This form closed on %', f.deadline
        using errcode = 'check_violation';
    end if;
  end if;

  select count(*) into recent
    from responses
   where form_id = new.form_id
     and submitted_at > now() - interval '1 minute';
  if recent >= 30 then
    raise exception 'This form is receiving too many responses right now. Try again in a minute.'
      using errcode = 'too_many_connections';
  end if;

  if jsonb_typeof(new.answers) is distinct from 'object' then
    raise exception 'Answers must be an object'
      using errcode = 'check_violation';
  end if;

  if octet_length(new.answers::text) > 20000 then
    raise exception 'That response is too long'
      using errcode = 'check_violation';
  end if;

  for key in select jsonb_object_keys(new.answers) loop
    if not exists (
      select 1 from jsonb_array_elements(f.questions) e where e->>'id' = key
    ) then
      raise exception 'This form has no question %', key
        using errcode = 'check_violation';
    end if;
  end loop;

  for q in select e from jsonb_array_elements(f.questions) e loop
    answer := new.answers -> (q->>'id');
    label  := coalesce(nullif(q->>'title', ''), 'untitled question');

    blank := answer is null
      or jsonb_typeof(answer) = 'null'
      or (jsonb_typeof(answer) = 'string' and btrim(answer #>> '{}') = '')
      or (jsonb_typeof(answer) = 'array' and jsonb_array_length(answer) = 0);

    if coalesce((q->>'required')::boolean, false) and blank then
      raise exception 'Answer required: %', label
        using errcode = 'check_violation';
    end if;

    if not blank then
      case q->>'type'

        when 'rating' then
          if jsonb_typeof(answer) = 'number' then
            num := (answer #>> '{}')::numeric;
          elsif jsonb_typeof(answer) = 'string' and (answer #>> '{}') ~ '^\d+$' then
            num := (answer #>> '{}')::numeric;
          else
            raise exception 'Not a rating: %', label using errcode = 'check_violation';
          end if;
          if num <> trunc(num)
             or num < 1
             or num > coalesce(nullif(q->>'maxRating', '')::numeric, 5) then
            raise exception 'Rating out of range: %', label using errcode = 'check_violation';
          end if;

        when 'number' then
          if not (jsonb_typeof(answer) = 'number'
                  or (jsonb_typeof(answer) = 'string'
                      and (answer #>> '{}') ~ '^-?\d+(\.\d+)?$')) then
            raise exception 'Not a number: %', label using errcode = 'check_violation';
          end if;

        when 'single-choice', 'dropdown' then
          if jsonb_typeof(answer) <> 'string'
             or not exists (
               select 1 from jsonb_array_elements_text(q->'options') o
                where o = answer #>> '{}'
             ) then
            raise exception 'Not one of the options: %', label using errcode = 'check_violation';
          end if;

        when 'multi-choice' then
          if jsonb_typeof(answer) <> 'array'
             or exists (
               select 1 from jsonb_array_elements(answer) a
                where jsonb_typeof(a) <> 'string'
                   or not exists (
                     select 1 from jsonb_array_elements_text(q->'options') o
                      where o = a #>> '{}'
                   )
             ) then
            raise exception 'Not one of the options: %', label using errcode = 'check_violation';
          end if;

        when 'email' then
          if jsonb_typeof(answer) <> 'string'
             or (answer #>> '{}') !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
            raise exception 'Not an email address: %', label using errcode = 'check_violation';
          end if;

        when 'date' then
          if jsonb_typeof(answer) <> 'string'
             or (answer #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then
            raise exception 'Not a date: %', label using errcode = 'check_violation';
          end if;

        when 'file' then
          expected := f.id || '/' || new.ref || '/' || (q->>'id');
          if jsonb_typeof(answer) <> 'string'
             or (answer #>> '{}') is distinct from expected then
            raise exception 'Not a photo: %', label using errcode = 'check_violation';
          end if;

        else
          if jsonb_typeof(answer) <> 'string' then
            raise exception 'Not text: %', label using errcode = 'check_violation';
          end if;
      end case;
    end if;
  end loop;

  return new;
end;
$guard$;
