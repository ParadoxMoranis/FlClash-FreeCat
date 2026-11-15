import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/form/form.dart';
import 'package:fl_clash/features/freecat/localization.dart';
import 'package:fl_clash/features/freecat/service.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum _FreecatField { email, password }

class FreecatAccountView extends ConsumerStatefulWidget {
  final int? profileId;

  const FreecatAccountView({super.key, this.profileId});

  @override
  ConsumerState<FreecatAccountView> createState() => _FreecatAccountViewState();
}

class _FreecatAccountViewState extends ConsumerState<FreecatAccountView> {
  final _hostController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  bool _readingAccount = false;
  bool _hasAccount = false;
  bool _saving = false;
  bool _attempted = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    final profileId = widget.profileId;
    if (profileId != null) {
      _readingAccount = true;
      unawaited(_readAccount(profileId));
    }
  }

  Future<void> _readAccount(int profileId) async {
    try {
      final account = await freecatService.readAccount(profileId);
      if (!mounted) return;
      _hasAccount = account != null;
      _hostController.text = account?.host ?? '';
      _emailController.text = account?.email ?? '';
    } catch (error) {
      if (mounted) _error = error;
    } finally {
      if (mounted) {
        setState(() {
          _readingAccount = false;
        });
      }
    }
  }

  ({_FreecatField field, String message})? _issue(
    AppLocalizations appLocalizations,
  ) {
    if (_emailController.text.trim().isEmpty) {
      return (
        field: _FreecatField.email,
        message: appLocalizations.emptyTip(appLocalizations.email),
      );
    }
    if (_passwordController.text.isEmpty) {
      return (
        field: _FreecatField.password,
        message: appLocalizations.emptyTip(appLocalizations.password),
      );
    }
    return null;
  }

  void _handleChanged(String _) {
    if (_attempted || _error != null) {
      setState(() {
        _error = null;
      });
    }
  }

  Future<void> _submit() async {
    if (_saving || _readingAccount) return;
    final issue = _issue(context.appLocalizations);
    if (issue != null) {
      setState(() {
        _attempted = true;
        _error = null;
      });
      switch (issue.field) {
        case _FreecatField.email:
          _emailFocusNode.requestFocus();
        case _FreecatField.password:
          _passwordFocusNode.requestFocus();
      }
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final host = _hostController.text.trim();
      await ref
          .read(profilesActionProvider.notifier)
          .importFreecat(
            email: _emailController.text.trim(),
            password: _passwordController.text,
            host: host.isEmpty ? null : host,
            profileId: widget.profileId,
          );
      if (mounted) {
        _passwordController.clear();
        if (ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _hostController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    final issue = _attempted ? _issue(appLocalizations) : null;
    final error = _error;
    final profileId = widget.profileId;
    final subscriptionInfo = profileId == null
        ? null
        : ref.watch(
            profilesProvider.select(
              (profiles) => profiles.getProfile(profileId)?.subscriptionInfo,
            ),
          );
    return FormPage(
      title: appLocalizations.freecat,
      saveLabel: appLocalizations.signIn,
      saving: _saving || _readingAccount,
      onSave: _submit,
      error:
          issue?.message ??
          (error == null ? null : freecatErrorMessage(error, appLocalizations)),
      children: [
        if (_readingAccount)
          const Center(child: ActivityIndicator())
        else ...[
          if (profileId != null && !_hasAccount)
            ListFooter(text: appLocalizations.freecatAccountMissingTip),
          ExcludeFocus(
            excluding: _saving,
            child: AbsorbPointer(
              absorbing: _saving,
              child: generateSection(
                title: appLocalizations.account,
                footer: appLocalizations.freecatHostTip,
                items: [
                  FormRow(
                    title: appLocalizations.host,
                    trailing: FormRowTextField(
                      controller: _hostController,
                      hintText: appLocalizations.optional,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      inputFormatters: TextInputLimits.limit(
                        TextInputLimits.url,
                      ),
                      onChanged: _handleChanged,
                      onFieldSubmitted: (_) => _emailFocusNode.requestFocus(),
                    ),
                  ),
                  FormRow(
                    title: appLocalizations.email,
                    invalid: issue?.field == _FreecatField.email,
                    trailing: FormRowTextField(
                      controller: _emailController,
                      focusNode: _emailFocusNode,
                      autofocus: true,
                      hintText: appLocalizations.required,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      inputFormatters: TextInputLimits.limit(
                        TextInputLimits.userName,
                      ),
                      onChanged: _handleChanged,
                      onFieldSubmitted: (_) =>
                          _passwordFocusNode.requestFocus(),
                    ),
                  ),
                  FormRow(
                    title: appLocalizations.password,
                    invalid: issue?.field == _FreecatField.password,
                    trailing: FormRowSecretTextField(
                      controller: _passwordController,
                      focusNode: _passwordFocusNode,
                      hintText: appLocalizations.required,
                      textInputAction: TextInputAction.done,
                      inputFormatters: TextInputLimits.limit(
                        TextInputLimits.password,
                      ),
                      onChanged: _handleChanged,
                      onFieldSubmitted: (_) => unawaited(_submit()),
                    ),
                  ),
                ],
              ),
            ),
          ),
          ListFooter(text: appLocalizations.freecatPasswordTip),
          if (profileId != null)
            ListFooter(text: appLocalizations.freecatReplaceAccountTip),
          if (subscriptionInfo != null)
            SubscriptionInfoDetailView(subscriptionInfo: subscriptionInfo),
        ],
      ],
    );
  }
}
