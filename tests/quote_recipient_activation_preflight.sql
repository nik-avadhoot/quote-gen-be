-- ═════ EXACT-RECIPIENT ACTIVATION: procedure and READ-ONLY checks (not yet authorised) ═════
--
-- Migration: supabase/migrations/20260923170000_quote_revision_exact_recipient.sql
-- Reviewed content: md5 6f1840003862b1a5e77a34c2829b1ec7 (LF). Persistent
-- activation needs its own explicit authorization; nothing here writes.
-- Every query below starts with SET TRANSACTION READ ONLY and is one SELECT.
--
-- THREE ACTIVATION CLAIMS, NOT EQUIVALENT (QUERY L reports each separately):
--   * connector_once_ok: one apply_migration of this file through the Supabase
--     connector is safe now. The connector records its own (apply-time) version,
--     so the file's older version cannot collide or re-order live history.
--   * db_push_ok: a CLI `supabase db push` from this checkout would apply ONLY
--     this file, in order. It needs every live version present locally AND no
--     unapplied local file sorting behind the live head AND this file as the only
--     unapplied one. As of 2026-09-24 it is FALSE: 20260923150000, 20260923183000
--     and 20260924044157 (Customer Pricing History, another workstream) and this
--     file all sort behind 20260924084505, so push refuses without --include-all,
--     and --include-all would also apply the CPH migrations.
--   * fresh_replay: replaying supabase/migrations onto an empty database
--     reproduces main. A ledger comparison can never prove this; it stays
--     'unproven' until a branch replay shows it (known blockers are in QUERY L).
--
-- PROCEDURE (one session owns it end to end; no other session applies,
-- renames or rehearses migrations while it runs):
--   1. Announce ownership of the apply to the other active sessions.
--   2. Immediately beforehand run QUERY L, then QUERY A and QUERY C. QUERY L
--      must show connector_once_ok=true (every refusal list [] and
--      connector_version_not_after_head=false). If its manifest is stale the
--      contract tests/test_migration_ledger_gate_contract.py fails first;
--      refresh it with that script's --write, never by hand. QUERY A must show:
--      mig_recipient=0, resolver_present=false, s9r_helpers=0,
--      send_batch_old_insert=1, every s9b_* and s9c_* anchor = 1,
--      send_batch_proposed_sku=true, issue_has_exact_rule=false,
--      s9c_has_Buyer=true, send_batch_has_resolver_call=false,
--      batches_customer_party_id=true, mig_u4=1. Keep QUERY C's output.
--      Any other value: stop, do not apply.
--   3. Verify the local file still hashes to the reviewed md5 above, then apply
--      its exact content ONCE with the connector's apply_migration, name
--      quote_revision_exact_recipient. The migration aborts atomically on any
--      anchor drift, so a failed apply leaves nothing behind; do not retry
--      with edited content.
--   4. list_migrations: record the version the connector assigned (the apply
--      time, not 20260923170000).
--   5. Rename the local file to <assigned version>_quote_revision_exact_recipient.sql
--      without changing a byte (git mv once tracked; keep LF).
--   6. Update only the direct filename references (currently:
--      tests/quote_recipient_rollback_rehearsal.sql (header and the \ir line),
--      tests/test_quote_recipient_gates_splice_contract.py,
--      tests/test_quote_recipient_identity_contract.py,
--      tests/test_u4_stored_suite_drift_contract.py UNTOUCHED key). Re-pin
--      nothing else; rerun those three contracts. Then refresh the ledger
--      manifest (test_migration_ledger_gate_contract.py --write) and rerun that
--      contract; its RECIPIENT constant moves to the new name.
--   7. Verify md5(statements[1]) for the new version equals the renamed local
--      file's md5 and 6f1840003862b1a5e77a34c2829b1ec7 (the U4 apply stored its
--      file as one statement: bb13e8e43ac37d4c2a365a38d57fbe94 on both sides).
--   8. Confirm the history holds exactly one exact-recipient entry (QUERY B:
--      mig_recipient=1) and the total rose by exactly one.
--   9. Run QUERY B and QUERY C. B must show every *_ok=true; C must equal the
--      pre-apply output (functions' ACL/definer/config, RLS and policies,
--      table grants, row counts).
--  10. Rerun QUERY L with the refreshed manifest. Expected after activation:
--      live_missing_locally, name_mismatch, fingerprint_mismatch,
--      unexplained_empty_history and missing_dependencies all []; the recipient
--      now appears under recipient_installed and recipient_file_absent (the
--      20260923170000 name is gone), so connector_once_ok=false: the gate
--      refuses a second activation by design.
--
-- WHY THE OLDER FILENAME IS SAFE FOR THE CONNECTOR: the connector records its
-- own (later) version, so live history stays ordered; step 5 then removes the
-- file-side hazard, a CLI `db push` seeing 20260923170000 as unapplied (it is
-- older than the latest applied 20260924084505, so push would demand
-- --include-all and then re-run a splice whose anchor is already gone, which
-- aborts). Renaming the file BEFORE the apply gains nothing on this route (the
-- connector ignores the file's version) and would invalidate the reviewed
-- references in step 6 twice.

-- ═════ QUERY L: migration-ledger gate (run FIRST; read-only) ═════
-- Compares live supabase_migrations.schema_migrations with the manifest of
-- local files below. Fingerprint = left(md5(text with `--` comments removed,
-- whitespace runs collapsed, ends trimmed), 16); comment/whitespace-only drift
-- is tolerated, anything else refuses, except the three pinned string-literal
-- drifts in known_drift (each pinned on BOTH sides, so any further change
-- refuses). The four empty_history versions are the pre-S0c baseline, recorded
-- live without statements. 20260922085000 was applied inline through the
-- connector on 2026-09-22 and had no local file; the local file was recovered
-- byte-for-byte from its live statement on 2026-09-24 (md5
-- 165c924db17970e40abd97f2e03f3f26), not newly authored.
set transaction read only;
with manifest(version, name, fp) as (values
-- BEGIN LOCAL MANIFEST (generated by tests/test_migration_ledger_gate_contract.py --write; do not edit)
  ('20260823111400', 'synthetic_baseline_out_of_band_rls_auto_enable', 'e3b31dd26fb8f3c1'),
  ('20260823111434', 'create_profiles_and_admin_helper', 'd72cbaa312d39dd5'),
  ('20260823111457', 'harden_set_updated_at_search_path', '413fe6a7566272d4'),
  ('20260904114045', 's0b_revoke_execute_rls_auto_enable', 'b45d7476110eed1b'),
  ('20260904141923', 's1a_foundation_org_access_rls', 'a851e10c22a39d81'),
  ('20260904142135', 's1a_fix_unindexed_foreign_keys', 'aa270bc3f6337a4f'),
  ('20260904142846', 'p2_1_pgtap_regression_harness', '155ed8791a0e71e6'),
  ('20260904142927', 'p2_1_fix_pgtap_search_path', '2491e6fb27d01427'),
  ('20260904143000', 'p2_1_fix_pgtap_search_path_syntax', '37ee95d7b8182c14'),
  ('20260904143024', 'p2_1_fix_pgtap_plan_wrapper', 'cdc8d3ba5e2996a5'),
  ('20260904143047', 'p2_1_fix_pgtap_no_plan_type', 'cbbba4ca854aadb8'),
  ('20260904143143', 'p2_1_fix_n8_assertion_string', '2b9e42a91e18f258'),
  ('20260904143300', 'p2_2_identity_rpcs_and_first_admin_bootstrap', '81fc1560a95e1898'),
  ('20260904143341', 'p2_2_seed_edit_lock_setting_on_bootstrap', '2856f907f6c4dfe8'),
  ('20260904143403', 'p2_2_bootstrap_regression_tests', '97f4b010f1a77f5b'),
  ('20260904144313', 'p2_3_family_b_party_masters', '1b3f53bfd5527fb4'),
  ('20260904144336', 'p2_3_family_b_regression_tests', '88f45f10c5da82a6'),
  ('20260904145418', 'p2_4_party_lifecycle_rpcs', '006a658b227084f0'),
  ('20260904145607', 'p2_4_persona_and_lifecycle_tests', '82e50b7fe3a65e70'),
  ('20260904145711', 'p2_4_fix_fixture_auth_handoff', '815c4276b4ea2abd'),
  ('20260904145839', 'p2_4_fix_fixture_claims_ordering', '0436eeef2261fbe8'),
  ('20260904145940', 'p2_4_fix_refseq_null_uniqueness', '42d6820221c1a823'),
  ('20260904150112', 'p2_4_revoke_public_execute_on_test_functions', '40ca89ad602fb765'),
  ('20260904151713', 'p2_5_admin_identity_rpcs_public', '6f05f6cbd79bac51'),
  ('20260904153645', 'p2_5_remove_profiles_dependency_from_tests', 'c4a62bf4539c5ea5'),
  ('20260904153744', 'p2_5_fix_legacy_dependency_guard_selfmatch', '40918d4161eb8758'),
  ('20260904154229', 'p2_5_index_pending_invitations_fk', 'f0ae4eaaadbb01fd'),
  ('20260904160851', 'p2_6_restore_private_definer_with_invoker_wrappers', '71aa9adcb43098c7'),
  ('20260904161111', 'p2_6_revoke_public_execute_on_set_updated_at', 'f0000f9ba9c04222'),
  ('20260905071253', 'p2_7_revoke_anon_reach_into_legacy_profiles', '7821df5c8888e26f'),
  ('20260905071316', 'p2_7_generalise_anon_deny_by_default_guard', '8dd357c3741d51e7'),
  ('20260905071509', 'p2_7_fix_definer_placement_search_path', '885e8deb0783938b'),
  ('20260905071723', 'p2_8_public_bootstrap_routing_shim', '669b19cbb2b08ad8'),
  ('20260905072034', 'p2_8_bootstrap_routing_tests_and_fixture_guard', '24d09a6ffb308c35'),
  ('20260905072111', 'p2_8_fix_quoted_search_path_list', '9ac1b1187865b3c2'),
  ('20260905075709', 'p2_9_invite_legacy_maker_multi_plant', '47388c14e5085075'),
  ('20260905075810', 'p2_9_multi_plant_access_matrix_tests', '3dc4ffa79e8e6758'),
  ('20260905075848', 'p2_9_fix_mp9_grant_insert_columns', '276d9d785b94c940'),
  ('20260905075923', 'p2_9_fix_b4_invitation_survival_assertion', '6ec3181a82d4c5c9'),
  ('20260905085506', 'p2_10_self_contained_synthetic_fixture_identity', 'bc24a961e173f6a8'),
  ('20260905085608', 'p2_10_continuity_without_profiles_and_fixture_integrity', 'd463a8b2bc3b24e4'),
  ('20260905085703', 'p2_10_fix_assertions_that_assumed_an_empty_app_users', 'cf783b8c226efefb'),
  ('20260905085748', 'p2_10_fix_s4_admin_attribution_assertion', '71a595cd29595e32'),
  ('20260905092734', 'p2_11_email_change_authorization_audit_and_session_revocation', '1de2537a479ae85a'),
  ('20260905092756', 'p2_12_plant_master_integrity_active_only_grants', 'd6da22ca5ad422be'),
  ('20260905092908', 'p2_12_email_and_plant_master_tests', 'e413d300f9d20026'),
  ('20260905123531', 'p2_13_atomic_multi_plant_user_creation', '37df6486b3c1acc5'),
  ('20260905123610', 'p2_13_atomic_creation_failure_injection_tests', '78ae5194b5206be6'),
  ('20260905123646', 'p2_13_fix_p3_for_overloaded_create_shim', 'd4c244be21021193'),
  ('20260905124819', 'p2_14_orphan_detection_support', '83822945266028ca'),
  ('20260905124957', 'p2_14_orphan_detection_tests', 'c259ca98e7c48790'),
  ('20260905125943', 'p2_15_greenfield_administrator_provisioning', '80ed5a9df216280c'),
  ('20260905130024', 'p2_15_greenfield_provisioning_tests', 'b86a8ec1ade0000b'),
  ('20260905130355', 'p2_16_fix_sf5_profiles_invariant', 'bb9d30ca02a9e618'),
  ('20260905130436', 'p2_16_keep_run_all_out_of_the_legacy_dependency_guard', '2b6ff0a7e7cd9e8d'),
  ('20260905134821', 's3c_remove_legacy_identity_objects', '7d2120ad037343a0'),
  ('20260905134942', 's3c_strict_absence_guards_without_exemptions', 'a4c69cb336f38e12'),
  ('20260905135032', 's3c_scope_cn7_to_application_schemas', '227ad95896379cf0'),
  ('20260905142014', 's4_1_family_c_construction_library', 'e73277f278537f5c'),
  ('20260905142150', 's4_1_construction_library_tests', '01e9fba4c5dc742e'),
  ('20260905142258', 's4_1_fix_pc_fixture_cleanup_order', '10f16965fc961388'),
  ('20260905142328', 's4_1_fix_revoke_public_execute_on_guard_triggers', 'a37dbae3ab361144'),
  ('20260905142733', 's4_2_family_c_sku_master', '0a8b7d511cf81f08'),
  ('20260905180917', 's4_2_sku_master_tests', '4c2fc3b7ac4c3c38'),
  ('20260905181119', 's4_2_fix_deactivated_literal_and_register_sku_master', '74f9840b6a8742fd'),
  ('20260905181308', 's4_2_fix_ps28_deactivation_sets_deactivated_at', 'e251e2a5aba6cfd1'),
  ('20260905181401', 's4_2_fix_index_sla_sku_party_composite_fk', '51d34277fbe018f4'),
  ('20260905182113', 's4_3_product_definition_workflow_rpcs', '0f3e9549a44139fe'),
  ('20260905182253', 's4_3_product_workflow_tests', '659c03b4821ec726'),
  ('20260905182427', 's4_3_fix_pw_cleanup_respects_merge_lineage', '7f061a934a2bdcc6'),
  ('20260905182459', 's4_3_register_product_workflow_in_run_all', 'dd9cc9ba3f067cf3'),
  ('20260905183611', 's4_4_rename_construction_gates_to_cl_prefix', '529003e8c31d0707'),
  ('20260905185255', 's4_5_repair_construction_version_maker_route', '717484b359001217'),
  ('20260905185404', 's4_5_family_c_authority_regression', '62c8bb3cc710b879'),
  ('20260905185548', 's4_5_fix_fa2_and_register_family_c_authority', '14b6c88dae1b34bd'),
  ('20260905192219', 's4_6_fixtures_mint_their_own_owner_identity', '5bfcb431aab25029'),
  ('20260905192332', 's4_6_point_family_c_suites_at_the_minted_owner', 'bd1884b731eda1ef'),
  ('20260905194319', 's5_1_family_d_group_masters', '525386c81ff15758'),
  ('20260905194450', 's5_1_family_d_group_masters_tests', 'eddab4ce27734314'),
  ('20260905194533', 's5_1_fix_map_guard_covers_insert_and_update_only', '41dc27b852d11cae'),
  ('20260905194702', 's5_2_family_d_plant_masters', 'a9985b18afd5d2d9'),
  ('20260905194804', 's5_2_family_d_plant_masters_tests', '19a8d8105b63c5db'),
  ('20260905194941', 's5_3_family_e_pricing_basis_releases', '39a04ebea4d585d0'),
  ('20260905195028', 's5_3_pricing_basis_workflow_rpcs', '80ed922a805e6141'),
  ('20260905195206', 's5_3_pricing_basis_tests', '59d66cbf1dd7eb39'),
  ('20260905195332', 's5_3_fix_pb_fixture_read_gate_and_component_assertion', '8001e83dacf72fe4'),
  ('20260905195507', 's5_3_fix_pb_three_assertions', 'b0f5248df7eb4308'),
  ('20260905195533', 's5_4_register_family_d_and_e_suites', '1732ca7dab9b9b5c'),
  ('20260906043804', 's5_5_family_de_inactive_persona_and_helper_hygiene', '649cb03fd7b79bfb'),
  ('20260906044153', 's6_1_family_f_batch_core', '828ce12488adfa69'),
  ('20260906044257', 's6_2_family_f_groups_and_rows', '511f1a9a25426c58'),
  ('20260906044359', 's6_3_family_f_sets_and_calculations', '9593e52a0d92de9c'),
  ('20260906044707', 's6_4_batch_locks_and_concurrency', '7916dd32759bad66'),
  ('20260906044827', 's6_5_batch_workspace_tests', '34624feff199dfac'),
  ('20260906044912', 's6_5_fix_bf_fixture_adopts_an_active_identity', '9e53f1f766565476'),
  ('20260906044947', 's6_5_fix_bf_fixture_party_capability', '008e9efbc054c558'),
  ('20260906045018', 's6_5_fix_bf_does_not_unpublish_a_construction', '52979d8e5a58a12b'),
  ('20260906045204', 's6_6_batch_sets_and_locks_tests', 'deb7ae2144a6c97a'),
  ('20260906045346', 's6_7_reclaim_authority_matches_cdm32', '005832fec7e77de5'),
  ('20260906045411', 's6_8_register_batch_workspace_suites', '015c18d04072fe45'),
  ('20260906102243', 's5_6_inactive_baseline_covers_every_asserted_table', 'e3d8da8baaf538b1'),
  ('20260906102505', 's5_7_pb10_names_the_constraint_that_rejects', '0eb3444a2e89b6f7'),
  ('20260906104150', 's6_9_row_integrity_guards_must_see_reality', '91b557d995a59d54'),
  ('20260906104345', 's6_10_set_cardinality_enforced_on_every_write_path', '8d6733827d920a12'),
  ('20260906104523', 's6_11_batch_row_lineage_is_allocated_not_accepted', 'cb913cc5f1a20298'),
  ('20260906104826', 's6_12_batch_profile_revision_operation', 'afc8eaa7d0263852'),
  ('20260906104933', 's6_13_batch_profile_revision_gates', '1d013264af5eda40'),
  ('20260906105310', 's6_14_takeover_reason_and_the_audit_boundary', '607828270bade121'),
  ('20260906105600', 's6_15_family_f_security_personas', '6037dfc39f3ca429'),
  ('20260906105637', 's6_16_register_the_correction_suites', '94144b0a216c3c2c'),
  ('20260906124652', 's6_17_every_lock_operation_checks_batch_access', '979c2da941c46de4'),
  ('20260906125452', 's6_18_the_content_version_boundary_is_declared', '342831c7e9ba7d32'),
  ('20260906160853', 's7_1_annual_interest_basis', 'f6b747b9dfabf0e9'),
  ('20260906161055', 's7_2_interest_override_carries_its_reason', '8591456ce2d95aa1'),
  ('20260906161259', 's7_3_supplier_paper_credit_cost', 'cb3c8cf189acd530'),
  ('20260906161853', 's7_4_interest_authority_gates', '5b3b514a3ccd7bd2'),
  ('20260906162123', 's7_4_fix_ia_gates_prove_the_constraint_not_the_capability', '3be69f1708ff1c95'),
  ('20260906162318', 's7_4_fix_ia4_was_a_silent_rls_no_op', '711ccb3a18b06ea3'),
  ('20260906162922', 's7_5_restore_content_version_boundary_and_guard_the_register', 'c656d1c79dc42b4b'),
  ('20260907023935', 's7_6_retire_the_fixed_payment_terms_map', '38d14ed6ee741b1a'),
  ('20260907065533', 'family_b_mutations_schema', '870bd945a006767e'),
  ('20260907065939', 'family_b_mutations_functions', 'f71fb256614d17ff'),
  ('20260907070509', 'family_b_mutations_tests', '6043efbb68a134ac'),
  ('20260907070644', 'family_b_mutations_fix_inactive_fixture', '30e7eb83fbc03600'),
  ('20260907070903', 'family_b_mutations_fix_admin_read_grant', '2cf003a566e0ae4a'),
  ('20260907071102', 'family_b_mutations_fix_function_names', '01f9dcd03cfa00c5'),
  ('20260907071251', 'family_b_mutations_fix_ambiguous_oid', '6d50897a2554081f'),
  ('20260907071705', 'family_b_mutations_fix_test_logic', '75780211aba05099'),
  ('20260907071937', 'family_b_mutations_fix_grants_and_drop_obsolete', 'fbd9bf922e5d87e6'),
  ('20260907072420', 'family_b_mutations_fix_batch_workspace_reassign_calls', 'c113459be4556e9f'),
  ('20260907122440', 'family_b_mutations_fix_unindexed_approved_by_fk', '024e8d5ebceabf8a'),
  ('20260907125813', 'family_b_mutations_revoke_service_role_execute', 'b5adcbaec79257ce'),
  ('20260907130316', 'family_b_mutations_restore_cfm26_service_role_check', '3116878fb2d5ff87'),
  ('20260907162324', 'u1_slice_a_party_edit_function', '342d6467fba5d7c1'),
  ('20260907162417', 'u1_slice_a_party_edit_tests', '99b706efbac6dbb6'),
  ('20260907162811', 'u1_slice_a_fix_pem_inactive_fixture', '060b60a610a67d31'),
  ('20260907163012', 'u1_slice_a_fix_pem_ambiguous_oid', '1a895a4a0545d40c'),
  ('20260907163239', 'u1_slice_a_fix_grants_on_new_functions', 'a95cc9d10f7a4fc3'),
  ('20260907164819', 'u1_slice_c_location_functions', 'bd7d12d600cc55c9'),
  ('20260907165153', 'u1_slice_c_location_tests', '4897878d084741f7'),
  ('20260908052900', 'd2_stale_cas_raises_pt409_not_40001', '9306439ded5d7560'),
  ('20260908112254', 'ua3_set_user_capabilities_and_admin_invariant', '857b9668ba202b35'),
  ('20260908112515', 'ua3_fix_execute_grant_on_set_user_capabilities', '45623ba4c98a5296'),
  ('20260908112819', 'ua3_user_capability_governance_tests', 'e04b09e4dbf8299a'),
  ('20260908112931', 'ua3_fix_test_fixture_deactivation_constraint', '1a298f88a8cdce1b'),
  ('20260908113153', 'ua3_fix_last_admin_test_uses_rolled_back_subtransaction', '0dcbbafd62f75dfc'),
  ('20260908113242', 'ua3_fix_last_admin_helper_role_scope', '2b69e32c073938e9'),
  ('20260908113333', 'ua3_fix_last_admin_call_site_role', 'aa346557d3ba1063'),
  ('20260908113412', 'ua3_revoke_public_execute_on_new_test_functions', '25d5ea6105b55576'),
  ('20260908120003', 'ua3_close_direct_grant_write_bypass', '0c34637b6358f64d'),
  ('20260908120022', 'ua3_register_bypass_closure_suite', '4ec9f985928ed27e'),
  ('20260908162229', 'ua5_status_operation_cas', '1102d4d32f2173bf'),
  ('20260908162346', 'ua5_realign_suites_to_the_cas_signature', '42692b68bba65da2'),
  ('20260908162419', 'ua5_user_status_governance_tests', '15a7763982f0d870'),
  ('20260908162440', 'ua5_register_status_governance_suite', '87b58f38537df107'),
  ('20260909105454', 's9_1_family_g_quote_schema', '46a60b25735861f2'),
  ('20260909110355', 's9_1_family_g_quote_schema_tests', 'ec291228f4885307'),
  ('20260909110640', 's9_1_revoke_execute_on_quote_schema_suite', 'ffa1607b53476264'),
  ('20260909111509', 's9_1_fix_snapshot_freight_reference_integrity', 'ac01615dd6b9b9b7'),
  ('20260909111611', 's9_1_snapshot_freight_reference_integrity_tests', '2b5f2979c6ec004a'),
  ('20260910033547', 's9p_1_row_addons_and_fluting_bcf', 'a73f4ba0ca577179'),
  ('20260910033606', 's9p_2_calculation_defaults_fluting_bcf', '2a9a9717ff830e69'),
  ('20260910033631', 's9p_3_batch_pricing_basis', '3443cf0e6bee9fa7'),
  ('20260910033657', 's9p_4_pricing_group_temporary_freight', 'd24f6ef1fa445f82'),
  ('20260910033733', 's9p_5_create_batch_pricing_basis_init', '83c8fc7887d472df'),
  ('20260910033811', 's9p_6_set_batch_pricing_basis', 'd1bd4ad359ff9b2b'),
  ('20260910034505', 's9p_7_calculation_persistence_tests', 'f5c28af4bb9aee21'),
  ('20260910034533', 's9p_8_register_calculation_persistence_suite', '82f8cdafa805d8cc'),
  ('20260910034825', 's9p_7a_fix_approver_needs_group_read_to_approve_components', '168773347ec59091'),
  ('20260910034910', 's9p_6a_fix_set_batch_pricing_basis_execute_grant', 'd4afdf799dd2859c'),
  ('20260910035820', 's9p_7b_suite_tears_down_its_own_fixtures', '3d2edbc85f5915f1'),
  ('20260910035905', 's9p_7c_calculation_persistence_is_self_contained', '5cb9a7131a37183f'),
  ('20260910035952', 's9p_3a_fix_composite_fk_index_coverage', 'a4a02dcfc1dbb6d7'),
  ('20260910084955', 's9p_9_revoke_batch_write_authority', 'e0ffff5a9b2604e1'),
  ('20260910085025', 's9p_10_drop_pricing_date_server_default', 'a000c915cb450fca'),
  ('20260910085122', 's9p_11a_batch_sets_fixture_supplies_plant_local_pricing_date', '7312b95de3a874c9'),
  ('20260910085343', 's9p_11b_batch_workspace_fixture_supplies_plant_local_pricing_date', '5cb86e16193b89d0'),
  ('20260910090154', 's9p_12_authority_correction_gates', '80c263eec0c24f7f'),
  ('20260910101030', 's9p_13_cp96b_proves_effective_column_authority', '7e37193b4a3eaf9f'),
  ('20260910142301', 's7r_1_attestation_keyring', '12f20d9326ee7059'),
  ('20260910142426', 's7r_2_fingerprint_encoders_and_serializer', '7cb65bd7957ff0cc'),
  ('20260910142458', 's7r_2a_fix_serializer_multiarg_unnest', '036d66081b4fef07'),
  ('20260910142604', 's7r_3_durable_state_resolvers', '3133ce00d3ea7961'),
  ('20260910142741', 's7r_4_qcf1_and_qpf1_gatherers', 'b35d9fceb8a97e58'),
  ('20260910142835', 's7r_5_qca1_attestation_verifier', 'fe07d2b8e819170f'),
  ('20260910143057', 's7r_6_inheritance_resolvers', '7f38100d5da3a28c'),
  ('20260910143234', 's7r_7_eligibility_effective_inputs_and_gatherer', '90712c8296bd005e'),
  ('20260910143344', 's7r_8_calculate_batch_row_writer', '10486e86102d1a4e'),
  ('20260910143459', 's7r_8a_fix_entry_point_execute_grants', 'b60e000be5580179'),
  ('20260910143654', 's7r_8b_fix_coalesce_is_a_sql_construct', 'edd9f16320e06cd0'),
  ('20260910143806', 's7r_8c_fix_hmac_lives_in_extensions', 'c5e0e1967257cc36'),
  ('20260910155828', 's7r_9_calculation_writer_tests', '8dbdc7edb4dff491'),
  ('20260910155855', 's7r_9a_fix_sku_transition_must_pass_through_active', 'eb10fb6b8c7be811'),
  ('20260910160244', 's7r_9b_hoist_signing_out_of_authenticated_blocks', 'ee1d52c9acc92bb5'),
  ('20260910160319', 's7r_9c_fix_freight_entry_written_while_version_draft', '0dde0f28e59792ed'),
  ('20260910160346', 's7r_10_register_calculation_writer_suite', '150d24761fd8e835'),
  ('20260910160430', 's7r_11_invert_s9p_cp80_boundary_gate', '251b1816d68f0183'),
  ('20260911050251', 's7r_12_supplier_credit_stays_in_rate_master', '923c184ce0f0f807'),
  ('20260911050635', 's7r_13_rate_master_separation_gates', '84e9bcf790daf4a1'),
  ('20260911070000', 's7r_14_effective_material_rate_boundary', '4b44ba1b963a9402'),
  ('20260911071000', 's7r_15_effective_material_rate_gates', '2eac7081736feadc'),
  ('20260911080000', 's9b_atomic_send', '74a649078c850b1e'),
  ('20260911081000', 's9b_atomic_send_gates', '3ba88bd036bea7fa'),
  ('20260911090000', 's9c_quote_workflow', '84c1bcf508d2219d'),
  ('20260911091000', 's9c_quote_workflow_gates', '49a69231273e75b6'),
  ('20260915084131', 'gsm_master', '6676868685286b73'),
  ('20260915084252', 'gsm_master_catalogue_gates', 'cad0fbe4c59a642b'),
  ('20260915100440', 'u4_customer_family_sectors', '1cd86a63698218d0'),
  ('20260915100521', 'u4_customer_family_sector_catalogue_gates', 'cc3212219e3f946b'),
  ('20260916165004', 'fix_gsm_and_u4_definer_execute_grants', '6d1c2dd3354b536c'),
  ('20260917024849', 'u2_sku_master_quote_fields_and_sets', '539e2388214f580c'),
  ('20260917024903', 'u2_sku_pricing_portfolio', '7736a5acddcdda72'),
  ('20260917025921', 'u2_test_fixtures_record_a_pricing_portfolio', '19326727749a650a'),
  ('20260917030403', 'u2_sku_master_governed_operations', '2515ba46b45dc0a7'),
  ('20260917030435', 'u2_proposed_skus_are_quotable', '8f7f47659c037082'),
  ('20260917154004', 'u2_sku_master_location_applicability', 'e129c313c0e1b160'),
  ('20260917154140', 'u2_sku_set_governed_operations', '7e3584a6ce197d1f'),
  ('20260917182121', 's9_1_fix_family_g_read_helper_execute', '354d281f9493a476'),
  ('20260917182138', 'register_gsm_and_customer_family_sector_suites', '0fef000d834667a7'),
  ('20260918040738', 'seed_nagpur_limited_beta_masters', '481004d5a05e4172'),
  ('20260918090723', 'scope_family_d_and_pricing_basis_test_cleanup', 'e5a48a107eadb4d5'),
  ('20260918090810', 'restore_nagpur_beta_freight_lane', '991aa5eb6b6a837d'),
  ('20260918091350', 'grant_snehal_nag_make_quote', '202415ccae0e33eb'),
  ('20260918094026', 'open_all_capabilities_to_beta_users', 'a000cae5f0672c3c'),
  ('20260922075206', 's4_7_admin_publish_and_adopt_construction', 'e2a858ade0aa987c'),
  ('20260922085000', 'beta_seed_indorama_36512_construction_and_sku', '64764e7f264e0313'),
  ('20260922144812', 'u5_governed_sector_master_operations', '42ce29ee29b33dff'),
  ('20260922144832', 'u5_governed_sector_master_gates', '67656e74b91c7866'),
  ('20260922145032', 'repair_run_all_catalogue_suite_projection', '14e6816c5e89be04'),
  ('20260922150221', 'fix_u5_sector_definer_execute_grants', '4c869afb89f04697'),
  ('20260923132556', 'batch_customer_handoff', '24f5c4b5ee2c3a75'),
  ('20260923150000', 'customer_pricing_history_p0_1', '4c1ff76518b59a1e'),
  ('20260923170000', 'quote_revision_exact_recipient', '8dd114aa28997996'),
  ('20260923183000', 'customer_pricing_history_p0_2', 'b57de833e05e9cfb'),
  ('20260924044157', 'customer_pricing_history_p0_4', 'e1214ca8b8a7d407'),
  ('20260924084505', 'u4_stored_suite_sector_drift', '038828a8c01f70a4'),
  ('20260924100057', 'customer_pricing_history_p0_4_1_sob_allocated_boxes', '867c7cd26b59acde')
-- END LOCAL MANIFEST
),
known_drift(version, live_fp, local_fp) as (values
  ('20260908113153', 'f4485844c55f5f33', '0dcbbafd62f75dfc'),
  ('20260909110355', 'cd3ddfbdbc1567bc', 'ec291228f4885307'),
  ('20260917030435', '77b124b6c8ee5ff6', '8f7f47659c037082')),
empty_history(version) as (values
  ('20260823111400'), ('20260823111434'), ('20260823111457'), ('20260904114045')),
required(version, name) as (values
  ('20260911080000', 's9b_atomic_send'),
  ('20260911090000', 's9c_quote_workflow'),
  ('20260917030435', 'u2_proposed_skus_are_quotable'),
  ('20260923132556', 'batch_customer_handoff'),
  ('20260924084505', 'u4_stored_suite_sector_drift')),
target(version, name) as (values ('20260923170000', 'quote_revision_exact_recipient')),
live as (
  select version, name,
         case when coalesce(cardinality(statements), 0) = 0 then null
              else left(md5(btrim(regexp_replace(regexp_replace(array_to_string(statements, E'\n'),
                     '--[^\n]*', '', 'g'), '\s+', ' ', 'g'))), 16) end as fp
    from supabase_migrations.schema_migrations),
head as (select max(version) as v, count(*) as n from live),
r as (select
  (select coalesce(jsonb_agg(l.version || ':' || l.name order by l.version), '[]') from live l
    where not exists (select 1 from manifest m where m.version = l.version)) as live_missing_locally,
  (select coalesce(jsonb_agg(l.version || ':' || l.name || '<>' || m.name order by l.version), '[]')
     from live l join manifest m on m.version = l.version where l.name <> m.name) as name_mismatch,
  (select coalesce(jsonb_agg(l.version || ':' || l.name order by l.version), '[]')
     from live l join manifest m on m.version = l.version
    where l.fp is not null and l.fp <> m.fp
      and not exists (select 1 from known_drift k
                       where k.version = l.version and k.live_fp = l.fp and k.local_fp = m.fp)) as fingerprint_mismatch,
  (select coalesce(jsonb_agg(l.version || ':' || l.name order by l.version), '[]') from live l
    where l.fp is null and l.version not in (select version from empty_history)) as unexplained_empty_history,
  (select coalesce(jsonb_agg(l.version || ':' || l.name order by l.version), '[]')
     from live l, target t
    where l.name ilike '%exact_recipient%'
       or l.fp = (select m.fp from manifest m where m.version = t.version)) as recipient_installed,
  (select coalesce(jsonb_agg(l.version || ':' || l.name), '[]')
     from live l join target t on t.version = l.version) as recipient_version_taken,
  (select coalesce(jsonb_agg(t.version || ':' || t.name), '[]') from target t
    where not exists (select 1 from manifest m where m.version = t.version and m.name = t.name)) as recipient_file_absent,
  (select coalesce(jsonb_agg(q.version || ':' || q.name order by q.version), '[]') from required q
    where not exists (select 1 from live l where l.version = q.version and l.name = q.name)
       or not exists (select 1 from manifest m where m.version = q.version and m.name = q.name)) as missing_dependencies,
  to_char(clock_timestamp() at time zone 'utc', 'YYYYMMDDHH24MISS') <= (select v from head) as connector_version_not_after_head,
  (select coalesce(jsonb_agg(m.version || ':' || m.name order by m.version), '[]') from manifest m
    where not exists (select 1 from live l where l.version = m.version)) as unapplied_local,
  (select coalesce(jsonb_agg(m.version || ':' || m.name order by m.version), '[]') from manifest m
    where not exists (select 1 from live l where l.version = m.version)
      and m.version < (select v from head)) as unapplied_behind_head)
select jsonb_build_object(
  'live_head', (select v from head),
  'live_total', (select n from head),
  'local_total', (select count(*) from manifest),
  'live_missing_locally', r.live_missing_locally,
  'name_mismatch', r.name_mismatch,
  'fingerprint_mismatch', r.fingerprint_mismatch,
  'unexplained_empty_history', r.unexplained_empty_history,
  'recipient_installed', r.recipient_installed,
  'recipient_version_taken', r.recipient_version_taken,
  'recipient_file_absent', r.recipient_file_absent,
  'missing_dependencies', r.missing_dependencies,
  'connector_version_not_after_head', r.connector_version_not_after_head,
  'unapplied_local', r.unapplied_local,
  'unapplied_behind_head', r.unapplied_behind_head,
  'connector_once_ok', r.live_missing_locally = '[]' and r.name_mismatch = '[]'
                       and r.fingerprint_mismatch = '[]' and r.unexplained_empty_history = '[]'
                       and r.recipient_installed = '[]' and r.recipient_version_taken = '[]'
                       and r.recipient_file_absent = '[]' and r.missing_dependencies = '[]'
                       and not r.connector_version_not_after_head,
  'db_push_ok', r.live_missing_locally = '[]' and r.name_mismatch = '[]'
                and r.fingerprint_mismatch = '[]' and r.unexplained_empty_history = '[]'
                and r.recipient_installed = '[]' and r.recipient_version_taken = '[]'
                and r.recipient_file_absent = '[]' and r.missing_dependencies = '[]'
                and r.unapplied_behind_head = '[]'
                and r.unapplied_local = jsonb_build_array('20260923170000:quote_revision_exact_recipient'),
  'fresh_replay', 'unproven: needs a branch replay. Known blockers: 20260922085000 selects the tester-created '
                  || 'Indo Rama prospect with INTO STRICT (no migration creates it), the four empty_history '
                  || 'baseline rows carry no statements, and the known_drift literals would replay the local text',
  'read_only', current_setting('transaction_read_only')) as ledger_gate
from r;

-- ═════ QUERY A: pre-apply preconditions and anchor counts ═════
set transaction read only;
select jsonb_build_object(
  'send_batch_old_insert', ((length(pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure), $z$  insert into public.quote_revisions(family_id, source_revision_id, workflow_status, created_by)
    values (v_family, p_source_revision, 'draft', v_actor) returning id into v_revision;$z$, ''))) / length($z$  insert into public.quote_revisions(family_id, source_revision_id, workflow_status, created_by)
    values (v_family, p_source_revision, 'draft', v_actor) returning id into v_revision;$z$)),
  'send_batch_proposed_sku', position('sku_withdrawn' in pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) > 0 and position('sku_not_published' in pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) = 0 and position('sku_version_unapproved' in pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) = 0,
  'send_batch_has_resolver_call', position('resolve_batch_quote_recipient' in pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) > 0,
  'issue_has_exact_rule', position('exact_recipient_identity_unavailable' in pg_get_functiondef('app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure)) > 0,
  's9c_has_Buyer', position('''Buyer''' in pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) > 0,
  's9b_b_setup', ((length(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  update public.batch_edit_locks set holder_user_id=p_other, released_at=null where batch_id=p_batch;
$z$, ''))) / length($z$  update public.batch_edit_locks set holder_user_id=p_other, released_at=null where batch_id=p_batch;
$z$)),
  's9b_b_auth', ((length(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  update public.delivery_groups set status='active' where pricing_group_id=p_pg;
$z$, ''))) / length($z$  update public.delivery_groups set status='active' where pricing_group_id=p_pg;
$z$)),
  's9b_b_sent', ((length(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  return next ok(v_rev is not null,'S9B-19 a complete Batch sends successfully');
$z$, ''))) / length($z$  return next ok(v_rev is not null,'S9B-19 a complete Batch sends successfully');
$z$)),
  's9b_b_clean', ((length(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  -- Owner-only fixture cleanup; application roles retain no delete authority.
$z$, ''))) / length($z$  -- Owner-only fixture cleanup; application roles retain no delete authority.
$z$)),
  's9b_b_tail', ((length(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  delete from public.quote_families where id=v_fam;
$z$, ''))) / length($z$  delete from public.quote_families where id=v_fam;
$z$)),
  's9c_c_decl', ((length(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  v_seq_id bigint; v_seq_before bigint; v_cap bigint;
$z$, ''))) / length($z$  v_seq_id bigint; v_seq_before bigint; v_cap bigint;
$z$)),
  's9c_c_issue', ((length(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  perform set_config('request.jwt.claims',p_mclaims,true);
  set local role authenticated;
  perform public.issue_quote_revision(p_revision,'Buyer',jsonb_build_object('city','Kolkata'),
    current_date,current_date+30);
  reset role;
  return next ok((select workflow_status='issued' and standing='current' and issued_by=p_maker
                   and addressee_name='Buyer' from public.quote_revisions where id=p_revision),
    'S9C-14 Issue is separate, attributed, and freezes the addressee');
$z$, ''))) / length($z$  perform set_config('request.jwt.claims',p_mclaims,true);
  set local role authenticated;
  perform public.issue_quote_revision(p_revision,'Buyer',jsonb_build_object('city','Kolkata'),
    current_date,current_date+30);
  reset role;
  return next ok((select workflow_status='issued' and standing='current' and issued_by=p_maker
                   and addressee_name='Buyer' from public.quote_revisions where id=p_revision),
    'S9C-14 Issue is separate, attributed, and freezes the addressee');
$z$)),
  's9c_c_rev2', ((length(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$    'S9C-19 revision Send adopts the existing family linearly and remains unnumbered');
$z$, ''))) / length($z$    'S9C-19 revision Send adopts the existing family linearly and remains unnumbered');
$z$)),
  's9c_c_rev3', ((length(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure), $z$  perform public.issue_quote_revision(v_rev3,'Buyer',null,current_date,current_date+30);
$z$, ''))) / length($z$  perform public.issue_quote_revision(v_rev3,'Buyer',null,current_date,current_date+30);
$z$)),
  'u4_text_in_replaced_fns', position('__u4_' in pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure) || pg_get_functiondef('app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure) || pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure) || pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) > 0,
  'drift_n_old', ((length(pg_get_functiondef('tests.__s7r_body()'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s7r_body()'::regprocedure), $z$  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, null); reset role;
$z$, ''))) / length($z$  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, null); reset role;
$z$)),
  'drift_n_u4', ((length(pg_get_functiondef('tests.__s7r_body()'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s7r_body()'::regprocedure), $z$  perform tests.__u4_attach_fixture_sector(v_fam, v_sec);
  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, v_sec); reset role;
$z$, ''))) / length($z$  perform tests.__u4_attach_fixture_sector(v_fam, v_sec);
  set local role authenticated; v_batch := public.create_batch(v_fam, v_kol, v_sec); reset role;
$z$)),
  'drift_t_rel', ((length(pg_get_functiondef('tests.__s7r_teardown()'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s7r_teardown()'::regprocedure), $z$  perform tests.__u4_release_fixture_sector('__S7R');
  delete from public.sectors         where sector_code = '__S7R';
$z$, ''))) / length($z$  perform tests.__u4_release_fixture_sector('__S7R');
  delete from public.sectors         where sector_code = '__S7R';
$z$)),
  'drift_t_del', ((length(pg_get_functiondef('tests.__s7r_teardown()'::regprocedure)) - length(replace(pg_get_functiondef('tests.__s7r_teardown()'::regprocedure), $z$  delete from public.sectors         where sector_code = '__S7R';
$z$, ''))) / length($z$  delete from public.sectors         where sector_code = '__S7R';
$z$)),
  'resolver_present', to_regprocedure('app_private.resolve_batch_quote_recipient(bigint)') is not null,
  's9r_helpers', (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='tests' and p.proname like '\_\_s9r\_%'),
  'batches_customer_party_id', exists (select 1 from information_schema.columns where table_schema='public' and table_name='batches' and column_name='customer_party_id'),
  'attestation_keys', (select count(*) from app_private.attestation_keys),
  'app_sequences', (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='S' and n.nspname in ('public','app_private','ref_private')),
  'mig_total', (select count(*) from supabase_migrations.schema_migrations),
  'mig_u4', (select count(*) from supabase_migrations.schema_migrations where version='20260924084505'),
  'mig_u4_name', (select string_agg(name, ',') from supabase_migrations.schema_migrations where version='20260924084505'),
  'mig_recipient', (select count(*) from supabase_migrations.schema_migrations where version='20260923170000' or name ilike '%exact_recipient%'),
  'mig_latest', (select max(version) from supabase_migrations.schema_migrations),
  'mig_after_20260923170000', (select string_agg(version || ':' || name, ', ' order by version) from supabase_migrations.schema_migrations where version > '20260923170000'),
  'fn_md5_send_batch', md5(pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)),
  'fn_md5_issue', md5(pg_get_functiondef('app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure)),
  'fn_md5_s9b', md5(pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)),
  'fn_md5_s9c', md5(pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)),
  'read_only', current_setting('transaction_read_only')) as pre_apply;

-- ═════ QUERY B: post-apply installation, ACLs and history ═════
set transaction read only;
select jsonb_build_object(
  'mig_recipient', (select count(*) from supabase_migrations.schema_migrations where name ilike '%exact_recipient%'),
  'mig_total', (select count(*) from supabase_migrations.schema_migrations),
  'resolver_ok', to_regprocedure('app_private.resolve_batch_quote_recipient(bigint)') is not null,
  'send_batch_ok', position('from app_private.resolve_batch_quote_recipient(p_batch) recipient'
                     in pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) > 0
                   and position('values (v_family, p_source_revision, ''draft'', v_actor) returning id into v_revision'
                     in pg_get_functiondef('app_private.send_batch(bigint,integer,bigint,bigint)'::regprocedure)) = 0,
  'send_batch_single_ok', (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                            where n.nspname = 'app_private' and p.proname = 'send_batch'),
  'issue_ok', position('exact_recipient_identity_unavailable'
                in pg_get_functiondef('app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure)) > 0,
  'issue_shape_ok', (select p.prosecdef and p.proconfig = array['search_path=""'] from pg_proc p
                      where p.oid = 'app_private.issue_quote_revision(bigint,text,jsonb,date,date)'::regprocedure),
  'gates_ok', position('''Buyer''' in pg_get_functiondef('tests.__s9c_gates(bigint,bigint,bigint,text,bigint,text,bigint)'::regprocedure)) = 0
              and position('__s9r_select_recipient(p_batch)' in pg_get_functiondef('tests.__s9b_gates(bigint,bigint,text,bigint,text,bigint)'::regprocedure)) > 0,
  's9r_helpers_ok', (select count(*) = 3 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'tests' and p.proname like '\_\_s9r\_%'),
  'resolver_acl_ok', not has_function_privilege('public', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE')
                     and not has_function_privilege('anon', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE')
                     and not has_function_privilege('authenticated', 'app_private.resolve_batch_quote_recipient(bigint)', 'EXECUTE'),
  'test_helpers_acl_ok', not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'tests' and p.proname in ('__s9r_select_recipient', '__s9r_cleanup', '__s9r_resolver_gates', '__s9b_gates', '__s9c_gates')
                            and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))),
  'anon_cannot_send_issue_ok', not has_function_privilege('anon', 'public.send_batch(bigint,integer)', 'EXECUTE')
                     and not has_function_privilege('anon', 'public.issue_quote_revision(bigint,text,jsonb,date,date)', 'EXECUTE')) as post_apply;

-- ═════ QUERY C: fingerprint that must be identical before and after ═════
-- The new resolver and S9R helpers are excluded (they do not exist before);
-- every pre-existing function keeps its ACL, definer flag and config.
set transaction read only;
select jsonb_build_object(
  'fn_security', (select md5(string_agg(p.oid::regprocedure::text || ':' || coalesce(p.proacl::text, 'default') || ':'
                                        || p.prosecdef || ':' || coalesce(p.proconfig::text, 'none'),
                                        ',' order by p.oid::regprocedure::text))
                    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname in ('public', 'app_private', 'ref_private', 'tests')
                     and p.proname not in ('resolve_batch_quote_recipient', '__s9r_select_recipient', '__s9r_cleanup', '__s9r_resolver_gates')),
  'rls', (select md5(string_agg(n.nspname || '.' || c.relname || ':' || c.relrowsecurity || c.relforcerowsecurity,
                                ',' order by n.nspname, c.relname))
            from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where c.relkind in ('r', 'p') and n.nspname in ('public', 'app_private', 'ref_private')),
  'policies', (select md5(string_agg(schemaname || '.' || tablename || '.' || policyname || ':' || cmd || ':' || roles::text
                                     || ':' || coalesce(qual, '') || ':' || coalesce(with_check, ''),
                                     ',' order by schemaname, tablename, policyname))
                 from pg_policies where schemaname in ('public', 'app_private', 'ref_private')),
  'table_grants', (select md5(string_agg(grantee || ':' || table_schema || '.' || table_name || ':' || privilege_type,
                                         ',' order by grantee, table_schema, table_name, privilege_type))
                     from information_schema.role_table_grants
                    where table_schema in ('public', 'app_private', 'ref_private')),
  'rows', jsonb_build_object(
    'quote_families', (select count(*) from public.quote_families),
    'quote_revisions', (select count(*) from public.quote_revisions),
    'quote_items', (select count(*) from public.quote_items),
    'quote_workflow_events', (select count(*) from public.quote_workflow_events),
    'batches', (select count(*) from public.batches),
    'batch_rows', (select count(*) from public.batch_rows),
    'parties', (select count(*) from public.parties),
    'customer_families', (select count(*) from public.customer_families),
    'group_capability_grants', (select count(*) from public.group_capability_grants),
    'plant_capability_grants', (select count(*) from public.plant_capability_grants),
    'app_users', (select count(*) from public.app_users),
    'attestation_keys', (select count(*) from app_private.attestation_keys))) as fingerprint;
