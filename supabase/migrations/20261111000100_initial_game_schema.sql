-- ALERTE CAMPUS: eight game entities. This migration is intentionally separate
-- from scenario content and from the future Moodle authentication integration.
-- Apply through the Supabase migration workflow only after review.

create table public.utilisateur (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users (id) on delete set null,
  moodle_issuer text not null check (btrim(moodle_issuer) <> ''),
  moodle_subject text not null check (btrim(moodle_subject) <> ''),
  cree_le timestamptz not null default now(),
  unique (moodle_issuer, moodle_subject)
);

create table public.phase (
  id uuid primary key default gen_random_uuid(),
  ordre integer not null unique check (ordre > 0),
  titre text not null check (btrim(titre) <> ''),
  description text,
  publiee boolean not null default false
);

create table public.enigme (
  id uuid primary key default gen_random_uuid(),
  phase_id uuid not null references public.phase (id) on delete restrict,
  ordre integer not null check (ordre > 0),
  titre text not null check (btrim(titre) <> ''),
  enonce text not null check (btrim(enonce) <> ''),
  type_validation text not null check (
    type_validation in ('texte', 'selection', 'action', 'objectifs_interactifs')
  ),
  version_regles smallint not null default 1 check (version_regles > 0),
  -- Private server-side rules. For text, store a keyed digest, never a plain answer.
  regles_validation jsonb not null check (jsonb_typeof(regles_validation) = 'object'),
  points integer not null default 0 check (points >= 0),
  unique (phase_id, ordre)
);

create table public.indice (
  id uuid primary key default gen_random_uuid(),
  enigme_id uuid not null references public.enigme (id) on delete restrict,
  niveau integer not null check (niveau > 0),
  contenu text not null check (btrim(contenu) <> ''),
  cout_points integer not null default 0 check (cout_points >= 0),
  unique (enigme_id, niveau),
  unique (enigme_id, id)
);

create table public.partie (
  id uuid primary key default gen_random_uuid(),
  mode_acces text not null check (mode_acces in ('moodle', 'test')),
  utilisateur_id uuid references public.utilisateur (id) on delete restrict,
  phase_courante_id uuid references public.phase (id) on delete restrict,
  statut text not null default 'en_cours' check (
    statut in ('en_cours', 'terminee', 'abandonnee', 'expiree')
  ),
  score integer not null default 0 check (score >= 0),
  -- Increment on every game-state change to reject stale concurrent writes.
  version integer not null default 1 check (version > 0),
  -- Copy the scenario's configured limit when the game starts. Never pause it.
  duree_max_secondes integer not null check (duree_max_secondes > 0),
  commencee_le timestamptz not null default now(),
  activite_le timestamptz not null default now(),
  terminee_le timestamptz,
  -- Test mode only: SHA-256 of a server-generated random 256-bit resume token.
  -- The raw token belongs only in a Secure, HttpOnly, SameSite cookie.
  jeton_reprise_hash bytea unique,
  jeton_reprise_expire_le timestamptz,
  constraint partie_identite_par_mode check (
    (mode_acces = 'moodle' and utilisateur_id is not null
      and jeton_reprise_hash is null and jeton_reprise_expire_le is null)
    or
    (mode_acces = 'test' and utilisateur_id is null
      and jeton_reprise_hash is not null and jeton_reprise_expire_le is not null)
  ),
  constraint partie_fin_coherente check (
    (statut = 'en_cours' and terminee_le is null)
    or (statut <> 'en_cours' and terminee_le is not null)
  ),
  constraint partie_dates_coherentes check (
    activite_le >= commencee_le
    and (terminee_le is null or terminee_le >= commencee_le)
    and (jeton_reprise_expire_le is null
      or jeton_reprise_expire_le > commencee_le)
  )
);

create table public.progression (
  id uuid primary key default gen_random_uuid(),
  partie_id uuid not null references public.partie (id) on delete cascade,
  enigme_id uuid not null references public.enigme (id) on delete restrict,
  statut text not null default 'non_commencee' check (
    statut in ('non_commencee', 'en_cours', 'resolue')
  ),
  -- Server-verified state for interactive objectives; never trust a client flag.
  etat_objectifs jsonb not null default '{}'::jsonb
    check (jsonb_typeof(etat_objectifs) = 'object'),
  commencee_le timestamptz,
  resolue_le timestamptz,
  unique (partie_id, enigme_id),
  constraint progression_dates_coherentes check (
    (statut = 'non_commencee' and commencee_le is null and resolue_le is null)
    or (statut = 'en_cours' and commencee_le is not null and resolue_le is null)
    or (statut = 'resolue' and commencee_le is not null
      and resolue_le is not null and resolue_le >= commencee_le)
  )
);

create table public.tentative (
  id uuid primary key default gen_random_uuid(),
  partie_id uuid not null,
  enigme_id uuid not null,
  -- Raw student answers are deliberately not persisted.
  est_correcte boolean not null,
  soumise_le timestamptz not null default now(),
  foreign key (partie_id, enigme_id)
    references public.progression (partie_id, enigme_id) on delete cascade
);

create table public.utilisation_indice (
  id uuid primary key default gen_random_uuid(),
  partie_id uuid not null,
  enigme_id uuid not null,
  indice_id uuid not null,
  utilise_le timestamptz not null default now(),
  unique (partie_id, indice_id),
  foreign key (partie_id, enigme_id)
    references public.progression (partie_id, enigme_id) on delete cascade,
  foreign key (enigme_id, indice_id)
    references public.indice (enigme_id, id) on delete restrict
);

create index partie_utilisateur_activite_idx
  on public.partie (utilisateur_id, activite_le desc)
  where utilisateur_id is not null;
create index progression_enigme_idx on public.progression (enigme_id);
create index tentative_partie_enigme_date_idx
  on public.tentative (partie_id, enigme_id, soumise_le desc);
create index utilisation_indice_partie_idx
  on public.utilisation_indice (partie_id);

-- RLS protects direct Data API access. Scenario content, validation rules,
-- answers, scoring and all writes are handled by trusted server endpoints.
alter table public.utilisateur enable row level security;
alter table public.phase enable row level security;
alter table public.enigme enable row level security;
alter table public.indice enable row level security;
alter table public.partie enable row level security;
alter table public.progression enable row level security;
alter table public.tentative enable row level security;
alter table public.utilisation_indice enable row level security;

revoke all on table public.utilisateur, public.phase, public.enigme,
  public.indice, public.partie, public.progression, public.tentative,
  public.utilisation_indice from public, anon, authenticated;

grant select on table public.utilisateur, public.partie, public.progression,
  public.tentative, public.utilisation_indice to authenticated;

-- The trusted server uses service_role and must check game rules itself.
grant select, insert, update, delete on table public.utilisateur, public.phase,
  public.enigme, public.indice, public.partie, public.progression,
  public.tentative, public.utilisation_indice to service_role;

create policy utilisateur_lire_soi on public.utilisateur
  for select to authenticated
  using (auth_user_id = (select auth.uid()));

create policy partie_lire_soi on public.partie
  for select to authenticated
  using (
    mode_acces = 'moodle'
    and exists (
      select 1 from public.utilisateur u
      where u.id = partie.utilisateur_id
        and u.auth_user_id = (select auth.uid())
    )
  );

create policy progression_lire_soi on public.progression
  for select to authenticated
  using (
    exists (
      select 1 from public.partie p where p.id = progression.partie_id
    )
  );

create policy tentative_lire_soi on public.tentative
  for select to authenticated
  using (
    exists (
      select 1 from public.partie p where p.id = tentative.partie_id
    )
  );

create policy utilisation_indice_lire_soi on public.utilisation_indice
  for select to authenticated
  using (
    exists (
      select 1 from public.partie p
      where p.id = utilisation_indice.partie_id
    )
  );

-- No anon grants/policies; no client INSERT/UPDATE/DELETE policies.
-- No direct client SELECT on enigme or indice because rows contain secrets.
