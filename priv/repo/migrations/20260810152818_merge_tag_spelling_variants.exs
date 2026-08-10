defmodule Vutuv.Repo.Migrations.MergeTagSpellingVariants do
  use Ecto.Migration

  @moduledoc """
  Folds tags that are the same topic written differently into one page each
  (issue #1338): `java script` into `javascript`, `OpenSource` into
  `open source`, `internet of things` into `iot`.

  ## What is in the list, and what deliberately is not

  Two kinds, both read through by hand against a copy of vutuv.de's catalog:

    * **Spelling variants** — the names agree once case, spaces, hyphens and
      underscores are folded away. `open source` / `OpenSource` / `Open-Source`.
    * **Seven abbreviations** — `seo`, `aws`, `hr`, `iot`, `crm`, `TDD` and the
      `js` / `javascript` pair. Nothing else: two-letter acronyms are almost all
      false friends (`Human Rights` is not `hr`, `Galactic Overlording` is not
      `go`).

  Not in the list, on purpose: anything that merely **shares a word**
  (`embedded linux` is not `Linux`, `Cake PHP` is not `PHP`, `Ruby` is not
  `Ruby on Rails`), **typos** (`javer script` stays its own tag, and so does the
  pair `javascipt` / `java scipt`, which would only canonicalise a misspelling),
  and the **German/English twins** (`projektmanagement` beside
  `project management`, `sales` beside `vertrieb`) — that is a product decision
  about which language a topic is filed under, not a spelling question.

  ## Why it cannot hurt an installation that does not have these tags

  Every entry names **slugs**, matched exactly. A tag that is absent is skipped,
  a group whose surviving tag is absent is skipped whole, and a group where
  nothing to absorb is present does nothing. A fresh database — CI, `mix test`,
  a new installation — therefore runs this migration as a complete no-op, which
  is also why the counts are printed rather than asserted.

  Slugs rather than names because a name is not unique: this very catalog holds
  two tags both called `Ember`, which is exactly one of the merges below.

  ## How it merges

  Through `Vutuv.Tags.Merge.merge/3`, the same code path the admin screen uses,
  rather than a second implementation in SQL. That buys the endorsement rescue
  (a member carrying both spellings keeps the vouches from both) and, above all,
  the ledger: **every single merge here is listed on `/admin/tag_merges` and can
  be reverted individually**, which a hand-written `UPDATE` would not give.
  `down/0` reverts them all in one go.

  The merge is skipped entirely if that module ever goes away, so the migration
  stays replayable on a fresh database years from now instead of crashing.

  Each absorbed name is filed as `alias` — "another name for this topic" — which
  is true of a spelling variant and of an abbreviation alike; nothing here was
  ever the surviving tag's own former name.

  ## Which tag survives

  The one with the most profiles, ties broken by the shorter name. That is a
  mechanical rule and it occasionally keeps the less pretty spelling
  (`it projectmanagement` over `it project management`). Flipping one afterwards
  is two clicks on `/admin/tag_merges`: revert, then merge the other way.

  N-1 safe: no schema change, and the release currently deployed already
  resolves an alias to its topic.
  """

  # {surviving slug, [absorbed slugs]}. The comment on each line is the state
  # this list was read from: name (profiles carrying it).
  @merges [
    # javascript (460) <- java script (8), js (24)
    {"javascript", ["java_script", "js"]},
    # Ruby on Rails (127) <- ROR (0), rubyonrails (0)
    {"ruby_on_rails", ["ror", "rubyonrails"]},
    # projektmanagement (93) <- projekt management (7), projekt-management (3)
    {"projektmanagement", ["projekt_management", "projekt_management.070d62e3"]},
    # open source (57) <- Open-Source (1), OpenSource (22)
    {"open_source", ["open_source.6b96633c", "opensource"]},
    # social media (72) <- social-media (3), SocialMedia (1)
    {"social_media", ["social_media.aa38d17a", "socialmedia"]},
    # online marketing (44) <- online-marketing (17), onlinemarketing (4)
    {"online_marketing", ["online_marketing.1dce9d0d", "onlinemarketing"]},
    # seo (63) <- search engine optimization (2)
    {"seo", ["search_engine_optimization"]},
    # project management (58) <- projectmanagement (2)
    {"project_management", ["projectmanagement"]},
    # devops (55) <- dev ops (1), dev-ops (1)
    {"devops", ["dev_ops", "dev_ops.e7c260e0"]},
    # Phoenix Framework (54) <- Phoenix-framework (0)
    {"phoenix_framework", ["phoenix-framework"]},
    # webdesign (40) <- web design (10), Web-Design (1)
    {"webdesign", ["web_design", "web_design.7f6a2daa"]},
    # html5 (48) <- html 5 (1)
    {"html5", ["html_5"]},
    # it-security (24) <- it security (17)
    {"it_security", ["it_security.192dee2a"]},
    # vmware (36) <- vm ware (1)
    {"vmware", ["vm_ware"]},
    # e-commerce (26) <- E Commerce (1), ecommerce (9)
    {"e_commerce", ["e_commerce.c449d1ae", "ecommerce"]},
    # change management (24) <- change-management (2), changemanagement (5)
    {"change_management", ["change_management.8b38db5e", "changemanagement"]},
    # aws (27) <- amazon web services (3)
    {"aws", ["amazon_web_services"]},
    # software development (27) <- Software-Development (1), SoftwareDevelopment (1)
    {"software_development", ["software_development.fcd6c912", "softwaredevelopment"]},
    # softwareentwicklung (21) <- software-entwicklung (4), software entwicklung (3)
    {"softwareentwicklung", ["software_entwicklung", "software_entwicklung.4ca5aae8"]},
    # nodejs (27) <- node js (1)
    {"nodejs", ["node-js"]},
    # hr (23) <- human resources (4)
    {"hr", ["human_resources"]},
    # objective-c (22) <- objective c (3), ObjectiveC (1)
    {"objective_c.00185723", ["objective_c", "objectivec"]},
    # systemadministration (18) <- system administration (7)
    {"systemadministration", ["system_administration"]},
    # angularjs (22) <- angular js (3)
    {"angularjs", ["angular_js"]},
    # active directory (21) <- Active-Directory (1), activedirectory (2)
    {"active_directory", ["active_directory.faecfa38", "activedirectory"]},
    # typo3 (23) <- typo 3 (1)
    {"typo3", ["typo_3"]},
    # iot (18) <- internet of things (6)
    {"iot", ["internet_of_things"]},
    # web development (17) <- web-development (2), webdevelopment (4)
    {"web_development", ["web_development.12bd0733", "webdevelopment"]},
    # macos (21) <- mac os (1)
    {"macos", ["mac_os"]},
    # cyber security (11) <- cybersecurity (10)
    {"cyber_security", ["cybersecurity"]},
    # sysadmin (17) <- Sys Admin (2)
    {"sysadmin", ["sys_admin"]},
    # it management (10) <- it-management (8)
    {"it_management", ["it_management.b2a3795a"]},
    # content marketing (15) <- content-marketing (2), contentmarketing (1)
    {"content_marketing", ["content_marketing.d26b4944", "contentmarketing"]},
    # crm (16) <- Customer-Relationship-Management (1), customer relationship management (1)
    {"crm", ["customer-relationship-management", "customer_relationship_management"]},
    # big data (15) <- BigData (2)
    {"big_data", ["bigdata"]},
    # c/c++ (15) <- c / c++ (1)
    {"c_c.847f12e2", ["c_c.0fade70d"]},
    # sql server (13) <- SQL-Server (1), sqlserver (2)
    {"sql_server", ["sql_server.92d7ba67", "sqlserver"]},
    # frontend (11) <- front-end (4), Front End (1)
    {"frontend", ["front_end", "front_end.f4dc5e49"]},
    # webentwicklung (11) <- web entwicklung (1), web-entwicklung (3)
    {"webentwicklung", ["web_entwicklung", "web_entwicklung.a88163e7"]},
    # TDD (12) <- test driven development (2), test-driven development (1)
    {"tdd", ["test_driven_development", "test_driven_development.2985bae1"]},
    # digital marketing (14) <- Digitalmarketing (1)
    {"digital_marketing", ["digitalmarketing"]},
    # redhat (10) <- Red Hat (5)
    {"redhat", ["red_hat"]},
    # product management (14) <- productmanagement (1)
    {"product_management", ["productmanagement"]},
    # mssql (8) <- ms sql (4), ms-sql (2)
    {"mssql", ["ms_sql", "ms_sql.7dbc2c4e"]},
    # start-ups (7) <- start ups (1), startups (5)
    {"start_ups.1111d736", ["start_ups", "startups"]},
    # software architektur (7) <- software-architektur (1), softwarearchitektur (4)
    {"software_architektur.8d8d6ccc", ["software_architektur", "softwarearchitektur"]},
    # Free Software (10) <- freesoftware (2)
    {"free_software", ["freesoftware"]},
    # content management (9) <- content-management (1), contentmanagement (2)
    {"content_management", ["content_management.2d53124c", "contentmanagement"]},
    # it-consulting (7) <- it consulting (5)
    {"it_consulting.b5a28166", ["it_consulting"]},
    # microsoft office (11) <- MicrosoftOffice (1)
    {"microsoft_office", ["microsoftoffice"]},
    # angular2 (8) <- angular 2 (3)
    {"angular2", ["angular_2"]},
    # netzwerkadministration (9) <- Netzwerk-Administration (1), - netzwerkadministration (1)
    {"netzwerkadministration.0e31fabd", ["netzwerk_administration", "netzwerkadministration"]},
    # it-sicherheit (9) <- it sicherheit (2)
    {"it_sicherheit", ["it_sicherheit.69c13424"]},
    # iso 27001 (6) <- iso27001 (5)
    {"iso_27001", ["iso27001"]},
    # java ee (10) <- javaee (1)
    {"java_ee", ["javaee"]},
    # ms office (9) <- ms-office (2)
    {"ms_office.686d3107", ["ms_office"]},
    # Ember (9) <- Ember (2)
    {"ember_js", ["ember"]},
    # produktmanagement (9) <- Produkt-Management (1)
    {"produktmanagement", ["produkt_management.1142de23"]},
    # vb.net (9) <- vb .net (1)
    {"vb_net", ["vb_net.930f95d4"]},
    # business intelligence (8) <- business-intelligence (2)
    {"business_intelligence", ["business_intelligence.9ca9af9e"]},
    # sap basis (8) <- SAP-Basis (1)
    {"sap_basis.799a6da6", ["sap_basis.980fea67"]},
    # scrum master (5) <- Scrum-Master (1), scrummaster (3)
    {"scrum_master", ["scrum_master.9c765f91", "scrummaster"]},
    # clean code (7) <- clean-code (2)
    {"clean_code", ["clean_code.be7cb23f"]},
    # data mining (6) <- datamining (2)
    {"data_mining", ["datamining"]},
    # personalmanagement (7) <- personal management (1)
    {"personalmanagement", ["personal_management"]},
    # grafikdesign (3) <- grafik-design (2), grafik design (3)
    {"grafikdesign", ["grafik_design", "grafik_design.acec02d6"]},
    # asp.net (7) <- asp .net (1)
    {"asp_net", ["asp_net.85c26e14"]},
    # wlan (7) <- w-lan (1)
    {"wlan", ["w_lan"]},
    # t-sql (7) <- TSQL (1)
    {"t_sql", ["tsql"]},
    # ux design (5) <- ux-design (3)
    {"ux_design", ["ux_design.58d56542"]},
    # servicemanagement (4) <- service management (3), service-management (1)
    {"servicemanagement", ["service_management", "service_management.db823881"]},
    # solidworks (6) <- solid works (2)
    {"solidworks", ["solid_works"]},
    # cloud computing (7) <- cloud-computing (1)
    {"cloud_computing", ["cloud_computing.98727faf"]},
    # it-infrastruktur (5) <- it infrastruktur (2)
    {"it_infrastruktur.49260fc8", ["it_infrastruktur"]},
    # test automation (4) <- testautomation (3)
    {"test_automation", ["testautomation"]},
    # react native (6) <- React-Native (1)
    {"react_native", ["react_native.d6abfc00"]},
    # YouTube (6) <- You Tube (1)
    {"youtube", ["you_tube"]},
    # DSGVO (6) <- ds-gvo (1)
    {"dsgvo", ["ds_gvo"]},
    # shell scripting (5) <- shell-scripting (1), shellscripting (1)
    {"shell_scripting", ["shell_scripting.b5885a36", "shellscripting"]},
    # it-projektmanagement (3) <- IT Projekt Management (1), it projektmanagement (3)
    {"it_projektmanagement", ["it_projekt_management", "it_projektmanagement.59759459"]},
    # team lead (4) <- teamlead (3)
    {"team_lead", ["teamlead"]},
    # mitarbeiterführung (6) <- mitarbeiter führung (1)
    {"mitarbeiterfuehrung", ["mitarbeiter_fuehrung"]},
    # spring boot (5) <- spring-boot (1)
    {"spring_boot", ["spring_boot.018cdb42"]},
    # os x (4) <- osx (2)
    {"os_x", ["osx"]},
    # webservices (5) <- web services (1)
    {"webservices", ["web_services"]},
    # check_mk (3) <- check-mk (1), checkmk (2)
    {"check_mk", ["check_mk.fe0f48a3", "checkmk"]},
    # software design (4) <- softwaredesign (2)
    {"software_design", ["softwaredesign"]},
    # webhosting (4) <- web-hosting (1), web hosting (1)
    {"webhosting", ["web_hosting", "web_hosting.6ed08108"]},
    # startup (5) <- start-up (1)
    {"startup", ["start_up"]},
    # artificial intelligence (6) <- ArtificialIntelligence (0)
    {"artificial_intelligence", ["artificialintelligence"]},
    # IT Consultant (4) <- IT-Consultant (2)
    {"it_consultant.585530eb", ["it_consultant"]},
    # frontend-development (2) <- front end development (1), Front-End Development (1), frontend development (2)
    {"frontend_development",
     ["front_end_development", "front_end_development.bc07a72b", "frontend_development.b477d9a9"]},
    # eventmanagement (3) <- event-management (1), event management (2)
    {"eventmanagement", ["event_management", "event_management.cc58c8d1"]},
    # e-mail marketing (4) <- email marketing (1), eMail-Marketing (1)
    {"e_mail_marketing", ["email_marketing", "email_marketing.eefd6ed8"]},
    # incident management (4) <- incidentmanagement (2)
    {"incident_management", ["incidentmanagement"]},
    # responsive webdesign (3) <- responsive web-design (1), responsive web design (2)
    {"responsive_webdesign", ["responsive_web_design", "responsive_web_design.d3747c40"]},
    # raspberry pi (5) <- RaspberryPi (1)
    {"raspberry_pi", ["raspberrypi"]},
    # high availability (5) <- HighAvailability (1)
    {"high_availability", ["highavailability"]},
    # business analyse (5) <- business-analyse (1)
    {"business_analyse", ["business_analyse.0b5bafab"]},
    # zend framework (5) <- zendframework (1)
    {"zend_framework", ["zendframework"]},
    # powerpoint (4) <- power point (2)
    {"powerpoint", ["power_point"]},
    # vmware vsphere (5) <- vmware-vsphere (1)
    {"vmware_vsphere", ["vmware_vsphere.b0aefc92"]},
    # team management (5) <- teammanagement (1)
    {"team_management", ["teammanagement"]},
    # storytelling (4) <- story telling (2)
    {"storytelling", ["story_telling"]},
    # spring framework (5) <- springframework (1)
    {"spring_framework", ["springframework"]},
    # autocad (4) <- auto cad (1)
    {"autocad", ["auto_cad"]},
    # healthcare (4) <- health care (1)
    {"healthcare", ["health_care"]},
    # windows 10 (4) <- windows10 (1)
    {"windows_10", ["windows10"]},
    # it service management (4) <- it-servicemanagement (1)
    {"it_service_management", ["it_servicemanagement.e9c34aa7"]},
    # cakephp (4) <- Cake PHP (1)
    {"cakephp", ["cake_php"]},
    # it-administration (3) <- it administration (2)
    {"it_administration.538bcf5b", ["it_administration"]},
    # visual studio (3) <- visualstudio (2)
    {"visual_studio", ["visualstudio"]},
    # datacenter (3) <- data center (2)
    {"datacenter", ["data_center"]},
    # it-strategie (4) <- it strategie (1)
    {"it_strategie", ["it_strategie.b28b20bf"]},
    # it projectmanagement (3) <- it project management (2)
    {"it_projectmanagement", ["it_project_management"]},
    # it architektur (3) <- it-architektur (2)
    {"it_architektur", ["it_architektur.4f45054a"]},
    # software engineer (4) <- software-engineer (1)
    {"software_engineer.7166c8a2", ["software_engineer"]},
    # knowledge management (4) <- knowledgemanagement (1)
    {"knowledge_management", ["knowledgemanagement"]},
    # e-learning (3) <- elearning (2)
    {"e_learning", ["elearning"]},
    # archlinux (4) <- arch linux (1)
    {"archlinux", ["arch_linux"]},
    # softwaretest (3) <- software test (1)
    {"softwaretest", ["software_test"]},
    # c#/.net (2) <- c# / .net (2)
    {"c_net", ["c_net.87e86ff0"]},
    # programm management (3) <- programmmanagement (1)
    {"programm_management", ["programmmanagement"]},
    # führungskräfte-coaching (2) <- führungskräfte coaching (1), führungskräftecoaching (1)
    {"fuehrungskraefte_coaching",
     ["fuehrungskraefte_coaching.7ddc227b", "fuehrungskraeftecoaching"]},
    # content strategie (3) <- content-strategie (1)
    {"content_strategie", ["content_strategie.33be94e9"]},
    # talent management (3) <- Talentmanagement (1)
    {"talent_management", ["talentmanagement"]},
    # server administration (2) <- server-administration (1), Serveradministration (1)
    {"server_administration", ["server_administration.38c108d5", "serveradministration"]},
    # microsoft hyper-v (2) <- microsoft-hyper-v (1), microsoft hyperv (1)
    {"microsoft_hyper_v", ["microsoft_hyper_v.c0a2c468", "microsoft_hyperv"]},
    # data management (3) <- datamanagement (1)
    {"data_management", ["datamanagement"]},
    # e-business (3) <- ebusiness (1)
    {"e_business", ["ebusiness"]},
    # ci/cd (3) <- CI / CD (1)
    {"ci_cd", ["ci_cd.00e9bbde"]},
    # community building (2) <- community-building (1), communitybuilding (1)
    {"community_building.ee810d81", ["community_building", "communitybuilding"]},
    # it audit (3) <- it-audit (1)
    {"it_audit.b845411f", ["it_audit"]},
    # design thinking (3) <- DesignThinking (1)
    {"design_thinking", ["designthinking"]},
    # digitale transformation (3) <- Digitaletransformation (1)
    {"digitale_transformation", ["digitaletransformation"]},
    # interaction design (3) <- interactiondesign (1)
    {"interaction_design", ["interactiondesign"]},
    # linux-systemadministration (3) <- linux systemadministration (1)
    {"linux_systemadministration", ["linux_systemadministration.4c4eb7e6"]},
    # information management (3) <- informationmanagement (1)
    {"information_management", ["informationmanagement"]},
    # office 365 (3) <- office365 (1)
    {"office_365", ["office365"]},
    # screendesign (3) <- Screen Design (1)
    {"screendesign", ["screen_design"]},
    # it-support (2) <- it support (2)
    {"it_support", ["it_support.5536ebb1"]},
    # business coaching (3) <- Business-Coaching (1)
    {"business_coaching", ["business_coaching.399df795"]},
    # problemmanagement (2) <- problem management (1), problem-management (1)
    {"problemmanagement", ["problem_management", "problem_management.0327195c"]},
    # FullStack (2) <- full-stack (1), full stack (1)
    {"fullstack", ["full_stack", "full_stack.01395cdf"]},
    # conversionoptimierung (2) <- conversion optimierung (2)
    {"conversionoptimierung", ["conversion_optimierung"]},
    # system administrator (3) <- systemadministrator (1)
    {"system_administrator", ["systemadministrator"]},
    # linux kernel (2) <- linux-kernel (1)
    {"linux_kernel", ["linux_kernel.e84fafb3"]},
    # s/4hana (2) <- s/4 hana (1)
    {"s_4hana", ["s_4_hana"]},
    # software-qualitätssicherung (2) <- softwarequalitätssicherung (1)
    {"software_qualitaetssicherung", ["softwarequalitaetssicherung"]},
    # backupstrategien (2) <- Backup-Strategien (1)
    {"backupstrategien", ["backup_strategien"]},
    # shell script (2) <- shellscript (1)
    {"shell_script", ["shellscript"]},
    # entity framework (2) <- entity-framework (1)
    {"entity_framework", ["entity_framework.4e108923"]},
    # budgetplanung (2) <- budget planung (1)
    {"budgetplanung", ["budget_planung"]},
    # Open-Source Software (2) <- open source software (1)
    {"open-source-software", ["open_source_software"]},
    # agile softwareentwicklung (2) <- agile software entwicklung (1)
    {"agile_softwareentwicklung", ["agile_software_entwicklung"]},
    # internet marketing (2) <- internetmarketing (1)
    {"internet_marketing", ["internetmarketing"]},
    # frontend entwicklung (2) <- Frontend-Entwicklung (1)
    {"frontend_entwicklung", ["frontend_entwicklung.12e983ed"]},
    # macos server (2) <- mac os server (1)
    {"macos_server", ["mac_os_server"]},
    # interim manager (2) <- Interim-Manager (1)
    {"interim_manager", ["interim_manager.1491a0da"]},
    # eventmarketing (1) <- event marketing (1), Event-Marketing (1)
    {"eventmarketing", ["event_marketing", "event_marketing.463cc0cd"]},
    # logo design (2) <- logodesign (1)
    {"logo_design", ["logodesign"]},
    # IT-Leitung (2) <- it leitung (1)
    {"it_leitung.ce095f58", ["it_leitung"]},
    # openWRT (2) <- Open Wrt (1)
    {"openwrt", ["open_wrt"]},
    # portfoliomanagement (2) <- portfolio management (1)
    {"portfoliomanagement", ["portfolio_management"]},
    # performance marketing (2) <- performancemarketing (1)
    {"performance_marketing", ["performancemarketing"]},
    # it-beratung (2) <- it beratung (1)
    {"it_beratung.443da6d2", ["it_beratung"]},
    # continous integration (2) <- continousintegration (1)
    {"continous_integration", ["continousintegration"]},
    # teambuilding (2) <- team building (1)
    {"teambuilding", ["team_building"]},
    # data warehouse (2) <- datawarehouse (1)
    {"data_warehouse", ["datawarehouse"]},
    # agile project management (2) <- agile Projectmanagement (1)
    {"agile_project_management", ["agile_projectmanagement"]},
    # c programming (2) <- C-Programming (1)
    {"c_programming", ["c_programming.c79e3eed"]},
    # macOSX (1) <- MAC OS X (1), mac osx (1)
    {"macosx", ["mac_os_x", "mac_osx"]},
    # Mitarbeiterentwicklung (2) <- mitarbeiter entwicklung (1)
    {"mitarbeiterentwicklung", ["mitarbeiter_entwicklung"]},
    # call center (2) <- CallCenter (1)
    {"call_center", ["callcenter"]},
    # Fullstack-developer (2) <- Full-Stack-Developer (1)
    {"fullstack-developer", ["full-stack-developer"]},
    # hr-marketing (2) <- hr marketing (1)
    {"hr_marketing", ["hr_marketing.d1565c9e"]},
    # ms sql server (2) <- MSSQL Server (1)
    {"ms_sql_server", ["mssql_server"]},
    # openxchange (1) <- open xchange (1), open-xchange (1)
    {"openxchange", ["open_xchange", "open_xchange.f230b5fe"]},
    # iso27000 (2) <- iso 27000 (1)
    {"iso27000", ["iso_27000"]},
    # helpdesk (2) <- help desk (1)
    {"helpdesk", ["help_desk"]},
    # datacenter management (2) <- Data Center Management (0)
    {"datacenter_management", ["data_center_management"]},
    # non-violent communication (1) <- non violent communication (1)
    {"non_violent_communication", ["non_violent_communication.534eb0c2"]},
    # DataWarehousing (1) <- Data Warehousing (1)
    {"datawarehousing", ["data_warehousing"]},
    # diplom kaufmann (1) <- Diplom-Kaufmann (1)
    {"diplom_kaufmann", ["diplom_kaufmann.88f2b9cc"]},
    # teamplayer (1) <- team player (1)
    {"teamplayer", ["team_player"]},
    # softwareentwickler (1) <- software-entwickler (1)
    {"softwareentwickler", ["software_entwickler"]},
    # Online Timesheet (1) <- Online Time Sheet (1)
    {"online_timesheet", ["online_time_sheet"]},
    # it-spezialisten (1) <- it spezialisten (1)
    {"it_spezialisten", ["it_spezialisten.8d479638"]},
    # android-apps (1) <- android apps (1)
    {"android_apps", ["android_apps.eb346d3d"]},
    # online kommunikation (1) <- Online-Kommunikation (1)
    {"online_kommunikation", ["online_kommunikation.22a67dc6"]},
    # design patterns (1) <- design-patterns (1)
    {"design_patterns", ["design_patterns.303534cb"]},
    # öffentlicheVerwaltung (1) <- öffentliche verwaltung (1)
    {"oeffentlicheverwaltung.b0912f86", ["oeffentliche_verwaltung"]},
    # presales consulting (1) <- pre sales consulting (1)
    {"presales_consulting", ["pre_sales_consulting"]},
    # web-seitenerstellung (1) <- webseiten erstellung (1)
    {"web_seitenerstellung", ["webseiten_erstellung"]},
    # unittesting (1) <- unit testing (1)
    {"unittesting", ["unit_testing"]},
    # performanceanalyse (1) <- performance-analyse (1)
    {"performanceanalyse", ["performance_analyse"]},
    # lpic1 (1) <- LPIC-1 (1)
    {"lpic1", ["lpic_1"]},
    # requirements-management (1) <- Requirements Management (1)
    {"requirements_management", ["requirements_management.bbe2c256"]},
    # Humanressources (1) <- Human Ressources (1)
    {"humanressources", ["human_ressources"]},
    # webseiten (1) <- web-seiten (1)
    {"webseiten", ["web_seiten"]},
    # Microsoft365 (1) <- Microsoft 365 (1)
    {"microsoft365", ["microsoft_365"]},
    # symphony2 (1) <- symphony 2 (1)
    {"symphony2", ["symphony_2"]},
    # OpenData (1) <- open data (1)
    {"opendata", ["open_data"]},
    # youtube-marketing (1) <- YouTube Marketing (1)
    {"youtube_marketing", ["youtube_marketing.383817be"]},
    # cinema4d (1) <- cinema 4d (1)
    {"cinema4d", ["cinema_4d"]},
    # PR Texter (1) <- PR-Texter (1)
    {"pr_texter", ["pr_texter.ce9c1d2e"]},
    # datawrangling (1) <- data wrangling (1)
    {"datawrangling", ["data_wrangling"]},
    # servervirtualisierung (1) <- Server-Virtualisierung (1)
    {"servervirtualisierung", ["server_virtualisierung.0722e7c4"]},
    # personaltraining (1) <- personal training (1)
    {"personaltraining", ["personal_training"]},
    # icecream (1) <- Ice cream (1)
    {"icecream", ["ice-cream"]},
    # SixSigma (1) <- six sigma (1)
    {"sixsigma", ["six_sigma"]},
    # Lifecoach (1) <- life coach (1)
    {"lifecoach", ["life_coach"]},
    # it operations (1) <- it-operations (1)
    {"it_operations", ["it_operations.adbaa105"]},
    # lpic2 (1) <- LPIC-2 (1)
    {"lpic2", ["lpic_2"]},
    # java entwickler (1) <- Java-Entwickler (1)
    {"java_entwickler", ["java_entwickler.1f73b559"]},
    # interimsmandate (1) <- interims-mandate (1)
    {"interimsmandate", ["interims_mandate"]},
    # releasemanagement (1) <- release-management (1)
    {"releasemanagement", ["release_management"]},
    # career coach (1) <- Career-Coach (1)
    {"career_coach", ["career_coach.af4f2547"]},
    # freebasics (1) <- free basics (1)
    {"freebasics", ["free_basics"]},
    # it betrieb (1) <- IT-Betrieb (1)
    {"it_betrieb", ["it_betrieb.ce1d80f9"]},
    # linux kvm (1) <- linux-kvm (1)
    {"linux_kvm", ["linux_kvm.93605f91"]},
    # it-know-how (1) <- it know-how (1)
    {"it_know_how", ["it_know_how.8a63c200"]},
    # Onlineshop (1) <- online shop (1)
    {"onlineshop", ["online_shop"]},
    # microstrategy (1) <- Micro Strategy (1)
    {"microstrategy", ["micro_strategy"]},
    # rechtsschutzversicherung (1) <- rechtsschutz-versicherung (1)
    {"rechtsschutzversicherung", ["rechtsschutz_versicherung"]},
    # Colocation (1) <- co-location (1)
    {"colocation", ["co_location"]},
    # jobsearch (1) <- job search (1)
    {"jobsearch", ["job_search"]},
    # mobiledevicemanagement (1) <- mobile device management (1)
    {"mobiledevicemanagement", ["mobile_device_management"]},
    # usability-testing (1) <- usability testing (1)
    {"usability_testing", ["usability_testing.a3745a35"]},
    # Mountainbike (1) <- mountain bike (1)
    {"mountainbike", ["mountain_bike"]},
    # hands-on-mentalität (1) <- Hands on Mentalität (1)
    {"hands_on_mentalitaet", ["hands_on_mentalitaet.0015a91d"]},
    # software testing (1) <- software-testing (0)
    {"software_testing", ["software-testing"]},
    # NoAI (1) <- no-ai (0)
    {"noai", ["no-ai"]},
    # hugging-face (0) <- Hugging Face (0)
    {"hugging-face", ["hugging-face.1159d4bc"]}
  ]

  @merge_module Vutuv.Tags.Merge
  @tag_module Vutuv.Tags.Tag

  @doc """
  The merges this migration performs, as `{surviving slug, [absorbed slugs]}`.
  Public so the test asserts against this list rather than a copy of it.
  """
  def merges, do: @merges

  def up, do: IO.puts("merge_tag_spelling_variants: " <> apply_merges(repo()))

  @doc """
  What `up/0` does, against an explicit repo, returning the report as a line.

  Public and repo-taking so the test drives **this** code rather than a copy of
  it: `repo/0` only answers inside a running migration.
  """
  def apply_merges(repo) do
    if available?() do
      report =
        Enum.reduce(
          @merges,
          %{merged: 0, groups: 0, missing: 0, failed: [], repo: repo},
          &merge_group/2
        )

      "#{report.merged} tags absorbed in #{report.groups} groups" <>
        ", #{report.missing} listed tags not present here" <>
        ", #{length(report.failed)} refused#{failures(report.failed)}"
    else
      "#{inspect(@merge_module)} is unavailable, nothing done"
    end
  end

  @doc """
  Reverts every merge this migration made and nobody has undone by hand.

  Recognised by having no admin behind it: a merge from the admin screen always
  records who did it, this one cannot. A merge already reverted stays reverted.
  """
  def down, do: IO.puts("merge_tag_spelling_variants: " <> revert_merges(repo()))

  @doc "What `down/0` does, against an explicit repo. See `apply_merges/1`."
  def revert_merges(repo) do
    if available?() do
      reverted =
        @merges
        |> Enum.flat_map(fn {_keeper, absorbed} -> absorbed end)
        |> Enum.map(&repo.get_by(@tag_module, slug: &1))
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(&merges_of(repo, &1))
        |> Enum.count(fn merge -> match?({:ok, _}, @merge_module.revert(merge)) end)

      "#{reverted} merges reverted"
    else
      "#{inspect(@merge_module)} is unavailable, nothing done"
    end
  end

  defp merge_group({keeper_slug, absorbed_slugs}, acc) do
    case acc.repo.get_by(@tag_module, slug: keeper_slug) do
      nil ->
        # The whole group belongs to a catalog this installation does not have.
        %{acc | missing: acc.missing + length(absorbed_slugs) + 1}

      keeper ->
        absorbed =
          absorbed_slugs
          |> Enum.map(&acc.repo.get_by(@tag_module, slug: &1))
          |> Enum.reject(&is_nil/1)

        acc = %{acc | missing: acc.missing + length(absorbed_slugs) - length(absorbed)}

        case absorbed do
          [] -> acc
          tags -> apply_merges(tags, keeper, acc)
        end
    end
  end

  defp apply_merges(tags, keeper, acc) do
    result = @merge_module.merge_all(tags, keeper, kind: "alias")

    %{
      acc
      | groups: acc.groups + 1,
        merged: acc.merged + length(result.merged),
        failed: acc.failed ++ Enum.map(result.failed, fn {tag, why} -> {tag.slug, why} end)
    }
  end

  # The unreverted merges recorded for this absorbed tag that no admin performed.
  defp merges_of(repo, tag) do
    import Ecto.Query

    repo.all(
      from(m in "tag_merges",
        where:
          m.absorbed_tag_id == type(^tag.id, Vutuv.UUIDv7) and is_nil(m.reverted_at) and
            is_nil(m.admin_user_id),
        select: m.id
      )
    )
    |> Enum.map(&@merge_module.get_merge(Ecto.UUID.cast!(&1)))
    |> Enum.reject(&is_nil/1)
  end

  # A migration must stay replayable long after the code around it has moved on,
  # so the one app module it leans on is checked rather than assumed.
  defp available? do
    Code.ensure_loaded?(@merge_module) and function_exported?(@merge_module, :merge_all, 3)
  end

  defp failures([]), do: ""

  defp failures(failed) do
    " (" <> Enum.map_join(failed, ", ", fn {slug, why} -> "#{slug}: #{why}" end) <> ")"
  end
end
